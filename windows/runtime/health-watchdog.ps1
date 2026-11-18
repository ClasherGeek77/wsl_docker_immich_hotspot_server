# health-watchdog.ps1 (v2) - layered health check + escalating self-heal for the
# WSL / Docker / Immich / zrok home server. Runs every 5 min from Task Scheduler.
#
# WHY v2 EXISTS
#   v1 had a single repair - `docker restart immich_zrok` - and fired it at every
#   failure. On 2026-08-16 the WSL resolver went dead (WSL's generated resolv.conf
#   points at a Windows-side DNS proxy that dies when the USB LTE modem
#   re-enumerates). zrok could no longer resolve api-v1.zrok.io, so it could not
#   build its Ziti session, so the public share 502'd. v1 restarted the container
#   3737 consecutive times over ~13 days without ever touching DNS, and never
#   reported that it was stuck.
#
# WHAT CHANGED
#   1. Layered probes (anchor -> WSL -> dockerd -> WSL DNS -> container DNS ->
#      Immich local -> zrok public -> container roster) so the BROKEN LAYER is
#      identified before anything is repaired.
#   2. An escalation ladder with persisted state: repeat failures climb to heavier
#      repairs instead of repeating the same ineffective one forever.
#   3. Backoff + alerting: once the ladder is exhausted the watchdog stops
#      hammering and writes a loud ALERT, so a stuck stack is visible.
#   4. Hard timeouts on every WSL call - v1 could hang forever on a wedged VM.
#   5. Log rotation - v1's logs reached 53 MB.
#   6. A machine-readable status file for out-of-band inspection.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Root      = Split-Path -Parent $PSScriptRoot
$StateDir  = Join-Path $Root 'state'
$LogFile   = 'C:\wsl-health.log'
$StateFile = Join-Path $StateDir 'health-state.json'
$StatusFile = Join-Path $StateDir 'health-status.json'
$IncidentLog = Join-Path $StateDir 'incidents.log'
$RebootFlag = Join-Path $StateDir 'ALLOW_REBOOT'

$MaxLogBytes = 5MB
$BackoffMinutes = 30          # pause after the ladder is exhausted
$LongBackoffMinutes = 120     # pause after 3 exhausted ladders

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

# --- SINGLE-INSTANCE LOCK ----------------------------------------------------
#
# A repair can run for minutes (Repair-WslNetwork tears down the VM, bounces ICS and
# waits for the network), while the scheduled task fires every 5 minutes and a human
# may kick off a run by hand at any time. Observed 2026-08-29: two Repair-WslNetwork
# runs executed concurrently, each shutting WSL down while the other was waiting for
# it to come back - they cancel each other out and the network never settles. Only
# one watchdog may act at a time; a second run simply exits.
$script:WdMutex = New-Object System.Threading.Mutex($false, 'Global\HomeServerHealthWatchdog')
$script:WdHeld = $false
try { $script:WdHeld = $script:WdMutex.WaitOne(0) } catch { $script:WdHeld = $true }
if (-not $script:WdHeld) {
    ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] Watchdog SKIPPED - another instance is already running.') |
        Out-File -FilePath $LogFile -Append -Encoding utf8
    return
}
trap { if ($script:WdHeld) { try { $script:WdMutex.ReleaseMutex() } catch { } }; break }

# --- logging -----------------------------------------------------------------

function Rotate-Log {
    param([string]$Path, [int]$MaxBytes)
    try {
        if ((Test-Path $Path) -and ((Get-Item $Path).Length -gt $MaxBytes)) {
            $r2 = $Path + '.2'; $r1 = $Path + '.1'
            if (Test-Path $r2) { Remove-Item $r2 -Force -ErrorAction SilentlyContinue }
            if (Test-Path $r1) { Move-Item $r1 $r2 -Force -ErrorAction SilentlyContinue }
            Move-Item $Path $r1 -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

Rotate-Log -Path $LogFile -MaxBytes $MaxLogBytes
Rotate-Log -Path 'C:\hotspot-log.txt' -MaxBytes $MaxLogBytes
Rotate-Log -Path $IncidentLog -MaxBytes 2MB

function Log($msg) {
    ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg) |
        Out-File -FilePath $LogFile -Append -Encoding utf8
}
function Incident($msg) {
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg
    $line | Out-File -FilePath $IncidentLog -Append -Encoding utf8
    Log $msg
}

# --- libs --------------------------------------------------------------------

. (Join-Path $Root 'lib\immich-guard.ps1')
try { . (Join-Path $Root 'lib\network-tuning.ps1') } catch { Log ('network-tuning load failed: ' + $_.Exception.Message) }

# --- state -------------------------------------------------------------------

function Read-State {
    $default = [pscustomobject]@{
        tier             = 0
        consecutiveFail  = 0
        laddersExhausted = 0
        lastFailLayer    = ''
        backoffUntilUtc  = ''
        lastOkUtc        = ''
        lastRunUtc       = ''
    }
    if (-not (Test-Path $StateFile)) { return $default }
    try {
        $s = Get-Content $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($p in $default.PSObject.Properties.Name) {
            if ($null -eq $s.PSObject.Properties[$p]) {
                $s | Add-Member -NotePropertyName $p -NotePropertyValue $default.$p -Force
            }
        }
        return $s
    } catch { return $default }
}

function Write-State($s) {
    try { $s | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding utf8 -Force } catch { }
}

$state = Read-State
$state.lastRunUtc = [datetime]::UtcNow.ToString('o')

# --- backoff gate ------------------------------------------------------------
# Without this the watchdog degenerates into v1's behaviour: a failure it cannot
# fix gets retried every 5 minutes forever, burning the box and hiding the fact
# that nothing is working.

if ($state.backoffUntilUtc) {
    try {
        $until = [datetime]::Parse($state.backoffUntilUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        if ([datetime]::UtcNow -lt $until) {
            # Still probe (cheap) so recovery is noticed, but do not repair.
            $z = Test-ZrokPublic
            if ($z.Ok) {
                Incident 'RECOVERED during backoff -> clearing alert state.'
                $state.tier = 0; $state.consecutiveFail = 0; $state.laddersExhausted = 0
                $state.backoffUntilUtc = ''; $state.lastOkUtc = [datetime]::UtcNow.ToString('o')
            } else {
                Log ('In backoff until ' + $until.ToString('u') + ' (zrok ' + $z.Detail + ') - no repair this cycle.')
            }
            # The status file MUST be refreshed on this path too. Returning early left
            # the previous cycle's JSON in place, so anything reading it during a
            # backoff saw stale - and often falsely healthy - data.
            try {
                [pscustomobject]@{
                    timestampUtc     = [datetime]::UtcNow.ToString('o')
                    healthy          = [bool]$z.Ok
                    inBackoff        = $true
                    backoffUntilUtc  = $until.ToString('o')
                    brokenLayer      = 'L7_zrokpub'
                    laddersExhausted = [int]$state.laddersExhausted
                    note             = 'backoff active - probing only, repairs suppressed'
                    layers           = [ordered]@{ L7_zrokpub = [ordered]@{ ok = [bool]$z.Ok; detail = [string]$z.Detail } }
                } | ConvertTo-Json -Depth 6 | Set-Content -Path $StatusFile -Encoding utf8 -Force
            } catch { }
            Write-State $state
            if ($script:WdHeld) {
                try { $script:WdMutex.ReleaseMutex() } catch { }
                try { $script:WdMutex.Dispose() } catch { }
            }
            return
        }
        $state.backoffUntilUtc = ''
    } catch { $state.backoffUntilUtc = '' }
}

# --- probe all layers --------------------------------------------------------

$results = [ordered]@{}
$brokenLayer = $null
$repairAttempted = $false
$repairTier = 0
$postRepairOk = $null

# Preventive, before any probing: keep icssvc running so the WSL network never
# gets a chance to collapse in the first place.
try { $ics = Ensure-IcsService -Log ${function:Log}; if ($ics.Detail -eq 'restarted') { Incident 'icssvc was stopped -> restarted preventively (owns WSL network)' } } catch { }
# Keep the upstream choice stable so ICS is not constantly re-bound (which is what
# destroys the WSL network). Safe by construction: only prefers a wired link that
# actually has internet. Also future-proofs the planned switch to a LAN cable.
try { Ensure-UpstreamMetrics -Log ${function:Log} | Out-Null } catch { }
# A disabled hotspot task is never correct at rest - it means a previous repair was
# interrupted before it could re-enable it, leaving the AP down with no way back.
try { $hs = Ensure-HotspotTaskEnabled -Log ${function:Log}; if ($hs.Repaired) { Incident 'AutoHotspotHealth was left Disabled -> re-enabled (interrupted repair)' } } catch { }

$results['L1_anchor']  = Test-KeepaliveAnchor
$results['L2_wsl']     = Test-WslUp
# L2b sits above dockerd deliberately: a NIC-less WSL VM runs dockerd and every
# container normally, so checking docker first would report the stack healthy.
$results['L2b_wslnet'] = if ($results['L2_wsl'].Ok) { Test-WslNetwork } else { @{ Ok = $false; Detail = 'skipped (WSL down)' } }
$results['L3_dockerd'] = if ($results['L2_wsl'].Ok) { Test-Dockerd } else { @{ Ok = $false; Detail = 'skipped (WSL down)' } }
$results['L4_wsldns']  = if ($results['L2b_wslnet'].Ok) { Test-WslDns } else { @{ Ok = $false; Detail = 'skipped (no WSL network)' } }
$results['L8_roster']  = if ($results['L3_dockerd'].Ok) { Test-ContainerRoster } else { @{ Ok = $false; Detail = 'skipped (dockerd down)'; Missing = @() } }
$results['L5_ctrdns']  = if ($results['L8_roster'].Ok) { Test-ContainerDns } else { @{ Ok = $false; Detail = 'skipped (roster incomplete)' } }
$results['L6_immich']  = if ($results['L3_dockerd'].Ok) { Test-ImmichLocal } else { @{ Ok = $false; Detail = 'skipped (dockerd down)' } }
$results['L7_zrokpub'] = Test-ZrokPublic

# The LAN path (phone -> hotspot -> netsh portproxy -> WSL) is invisible to every probe
# above: if the portproxy points at a stale WSL IP, zrok still works and the whole stack
# reports healthy while phones cannot reach Immich at all. Re-assert it every cycle.
# Needs the VM alive to read its current IP, so it is skipped when WSL is down.
$portProxy = @{ Ok = $false; Detail = 'skipped (WSL down)' }
if ($results['L2_wsl'].Ok) {
    try {
        $portProxy = Ensure-PortProxy -Log ${function:Log}
        if ($portProxy.Repaired) { Incident ('portproxy corrected -> ' + $portProxy.Detail) }
        elseif (-not $portProxy.Ok) { Log ('portproxy PROBLEM: ' + $portProxy.Detail) }
    } catch { $portProxy = @{ Ok = $false; Detail = $_.Exception.Message } }
}

$summary = ($results.Keys | ForEach-Object {
    $mark = if ($results[$_].Ok) { 'OK' } else { 'FAIL' }
    $_ + '=' + $mark
}) -join ' '

# The first failing layer, in dependency order, is what to repair. Repairing a
# higher layer while a lower one is broken is exactly the mistake v1 made.
foreach ($k in $results.Keys) {
    if (-not $results[$k].Ok) { $brokenLayer = $k; break }
}

$allOk = ($null -eq $brokenLayer)

if ($allOk) {
    if ($state.consecutiveFail -gt 0) {
        Incident ('RECOVERED after ' + $state.consecutiveFail + ' failed cycles (was ' + $state.lastFailLayer + ', tier ' + $state.tier + ').')
    }
    Log ('HEALTHY | ' + $summary)
    $state.tier = 0; $state.consecutiveFail = 0; $state.laddersExhausted = 0
    $state.lastFailLayer = ''; $state.lastOkUtc = [datetime]::UtcNow.ToString('o')
} else {
    # Reset the ladder when the failure MOVES to a different layer - the previous
    # tier count belongs to a different problem.
    if ($state.lastFailLayer -ne $brokenLayer) {
        $state.tier = 0
        $state.consecutiveFail = 0
        $state.lastFailLayer = $brokenLayer
    }
    $state.consecutiveFail = [int]$state.consecutiveFail + 1

    Log ('UNHEALTHY broken=' + $brokenLayer + ' (' + $results[$brokenLayer].Detail + ') fail#' + $state.consecutiveFail + ' | ' + $summary)

    # One transient blip should not trigger a repair; two consecutive should.
    if ($state.consecutiveFail -lt 2) {
        Log 'Single failure - waiting one cycle to confirm before repairing (hysteresis).'
    } else {
        $state.tier = [int]$state.tier + 1
        $tier = [int]$state.tier
        $repairAttempted = $true
        $repairTier = $tier
        Incident ('REPAIR tier ' + $tier + ' for ' + $brokenLayer)

        $repair = $null
        switch ($brokenLayer) {

            'L1_anchor' {
                Start-ScheduledTask -TaskName 'AutoStartWSL' -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 15
                $repair = @{ Ok = (Test-KeepaliveAnchor).Ok; Detail = 'restarted AutoStartWSL' }
            }

            'L2_wsl'     { $repair = Repair-WslRestart -Log ${function:Log} }

            # Only one thing fixes a NIC-less WSL VM, so go straight to it rather
            # than wasting tiers on restarts that provably do not help.
            'L2b_wslnet' { $repair = Repair-WslNetwork -Log ${function:Log} }

            'L3_dockerd' {
                if ($tier -le 2) { $repair = Repair-Dockerd }
                else             { $repair = Repair-WslRestart -Log ${function:Log} }
            }

            # DNS ladder - the failure mode that broke the box for 13 days.
            'L4_wsldns' {
                if ($tier -eq 1) { $repair = Repair-WslDns }
                elseif ($tier -eq 2) {
                    $repair = Repair-WslDns
                    if (-not $repair.Ok) { $repair = Repair-Dockerd }
                }
                else { $repair = Repair-WslRestart -Log ${function:Log} }
            }

            'L5_ctrdns' {
                if ($tier -eq 1)     { $r1 = Repair-WslDns; Log ('  dns: ' + $r1.Detail); $repair = Repair-ZrokRestart }
                elseif ($tier -eq 2) { $repair = Repair-ZrokRecreate }
                elseif ($tier -eq 3) { $repair = Repair-Dockerd }
                else                 { $repair = Repair-WslRestart -Log ${function:Log} }
            }

            'L6_immich' {
                if ($tier -le 2)     { $repair = Repair-ComposeUp }
                elseif ($tier -eq 3) { $repair = Repair-Dockerd }
                else                 { $repair = Repair-WslRestart -Log ${function:Log} }
            }

            # zrok public is down while everything under it is healthy: the tunnel
            # itself is stale (zrok keeps running while its Ziti session is dead,
            # so restart:always never helps).
            'L7_zrokpub' {
                if ($tier -eq 1)     { $repair = Repair-ZrokRestart }
                elseif ($tier -eq 2) { $r1 = Repair-WslDns; Log ('  dns: ' + $r1.Detail); $repair = Repair-ZrokRecreate }
                elseif ($tier -eq 3) { $repair = Repair-Dockerd }
                else                 { $repair = Repair-WslRestart -Log ${function:Log} }
            }

            'L8_roster' {
                $missing = $results['L8_roster'].Missing
                if ($tier -eq 1 -and $missing -and $missing.Count -gt 0) { $repair = Repair-ContainerStart -Names $missing }
                elseif ($tier -le 3) { $repair = Repair-ComposeUp }
                else                 { $repair = Repair-Dockerd }
            }

            default { $repair = @{ Ok = $false; Detail = 'no repair mapped for ' + $brokenLayer } }
        }

        Log ('  repair result: ok=' + $repair.Ok + ' detail=' + $repair.Detail)

        # Verify against the outside world, which is the only thing that matters.
        #
        # 2026-08-31: a full VM-level repair (Repair-WslRestart / Repair-WslNetwork)
        # does `wsl --shutdown`, which kills every container including zrok. zrok
        # comes back via restart:always but then has to cold-start a fresh Ziti
        # session against api-v1.zrok.io before the public URL answers - observed
        # taking ~35-40s in practice. The old flat 12s wait was tuned for the
        # lighter repairs (container restart/recreate, DNS repin) and was too short
        # for a VM-level rebuild: it could see zrok still warming up, call the tier
        # unhealed, and escalate to a heavier repair that was never actually needed.
        $vmLevelRepair = $brokenLayer -in @('L1_anchor', 'L2_wsl', 'L2b_wslnet') -or
                         ($brokenLayer -in @('L3_dockerd', 'L4_wsldns', 'L5_ctrdns', 'L6_immich', 'L7_zrokpub', 'L8_roster') -and $tier -ge 4)
        $verifyWaitSec = if ($vmLevelRepair) { 45 } else { 12 }
        Start-Sleep -Seconds $verifyWaitSec
        $verify = Test-ZrokPublic
        $postRepairOk = [bool]$verify.Ok
        Log ('  post-repair zrok (waited ' + $verifyWaitSec + 's): ' + $verify.Detail)

        if ($verify.Ok) {
            Incident ('HEALED at tier ' + $tier + ' (' + $brokenLayer + ').')
            $state.tier = 0; $state.consecutiveFail = 0; $state.laddersExhausted = 0
            $state.lastFailLayer = ''; $state.lastOkUtc = [datetime]::UtcNow.ToString('o')
        } elseif ($tier -ge 4) {
            # Ladder exhausted. Stop hammering; make the failure loud instead.
            $state.laddersExhausted = [int]$state.laddersExhausted + 1
            $mins = if ($state.laddersExhausted -ge 3) { $LongBackoffMinutes } else { $BackoffMinutes }
            $state.backoffUntilUtc = [datetime]::UtcNow.AddMinutes($mins).ToString('o')
            $state.tier = 0
            Incident ('ALERT: escalation ladder EXHAUSTED for ' + $brokenLayer +
                      ' (ladder #' + $state.laddersExhausted + '). Backing off ' + $mins +
                      ' min. MANUAL INTERVENTION LIKELY NEEDED.')
            if (Test-Path $RebootFlag) {
                Incident 'ALLOW_REBOOT flag present -> restarting Windows.'
                Restart-Computer -Force
            } else {
                Incident ('Automatic reboot NOT attempted (no ALLOW_REBOOT flag). Create ' + $RebootFlag + ' to opt in.')
            }
        }
    }
}

# --- modem tuning (runtime-only settings, reset on reboot) --------------------
try { Set-ModemClampMss -Log ${function:Log} } catch { Log ('ClampMss skipped: ' + $_.Exception.Message) }

# --- machine-readable status -------------------------------------------------

try {
    $statusLayers = [ordered]@{}
    foreach ($k in $results.Keys) { $statusLayers[$k] = [ordered]@{ ok = [bool]$results[$k].Ok; detail = [string]$results[$k].Detail } }
    # `layers` is the pre-repair snapshot, so on a repair cycle it always shows the
    # fault. Fold the post-repair verification into `healthy` as well, otherwise a
    # cycle that successfully healed still reports healthy=false to anyone reading
    # this file, which reads as "still broken".
    $effectiveHealthy = $allOk -or ($repairAttempted -and $postRepairOk -eq $true)
    [pscustomobject]@{
        timestampUtc     = [datetime]::UtcNow.ToString('o')
        healthy          = $effectiveHealthy
        healthyBeforeRepair = $allOk
        repairAttempted  = $repairAttempted
        repairTier       = $repairTier
        postRepairOk     = $postRepairOk
        brokenLayer      = $brokenLayer
        tier             = [int]$state.tier
        consecutiveFail  = [int]$state.consecutiveFail
        laddersExhausted = [int]$state.laddersExhausted
        backoffUntilUtc  = $state.backoffUntilUtc
        lastOkUtc        = $state.lastOkUtc
        portProxy        = [ordered]@{ ok = [bool]$portProxy.Ok; detail = [string]$portProxy.Detail }
        layers           = $statusLayers
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $StatusFile -Encoding utf8 -Force
} catch { Log ('status write failed: ' + $_.Exception.Message) }

Write-State $state

if ($script:WdHeld) {
    try { $script:WdMutex.ReleaseMutex() } catch { }
    try { $script:WdMutex.Dispose() } catch { }
}
