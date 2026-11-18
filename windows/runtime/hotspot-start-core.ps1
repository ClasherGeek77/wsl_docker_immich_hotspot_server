# hotspot-start.ps1
# Starts the hotspot - works as SYSTEM or interactive.
# HARDENED 2026-06-06: waits for an internet profile (USB modem may be slow at
# boot), then verifies tethering actually reaches On and RETRIES, instead of
# fire-and-forget (which silently no-ops if the modem/radio isn't ready yet).
# SSID/passphrase come from $env:HOTSPOT_SSID / $env:HOTSPOT_PASSPHRASE.
# Logs to C:\hotspot-log.txt

$logFile = "C:\hotspot-log.txt"
function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Out-File -Append -FilePath $logFile -Encoding UTF8
}

. (Join-Path $PSScriptRoot '..\lib\network-tuning.ps1')
. (Join-Path $PSScriptRoot '..\lib\hotspot-nat-guard.ps1')

Log "=== hotspot-start.ps1 (hardened) ==="

# Re-entrancy guard: Repair-HotspotNat may invoke this script as its adapter-
# recreate fallback. When it does, skip the NAT-check branch (which would call
# Repair again) and fall straight through to the plain radio start/retry loop.
$script:InRepairRestart = ($env:HOTSPOT_REPAIR_RESTART -eq '1')

# --- FAILURE COOLDOWN (added 2026-08-29) ------------------------------------
#
# WHY THIS EXISTS - this was the cause of the "server dies every few days".
#
# When tethering cannot reach On (e.g. the upstream is Wi-Fi "FailoverZone" rather
# than the USB modem, and the Wi-Fi adapter will not do AP+STA at once), this script
# fired StartTetheringAsync 5 times per run, and AutoHotspotHealth runs it every
# 60 seconds - a permanent ICS churn storm.
#
# WSL2's own network is an ICS-type HNS network ("WSL", Type=ICS). That churn
# destroys it: the WSL VM comes back with NO eth0 at all, so every container loses
# external networking, so zrok 502s and Immich becomes unreachable from outside
# while still serving fine on localhost. Restarting the zrok container - the only
# thing the old watchdog knew how to do - could never fix that.
#
# The retries are still worth making (conditions do change), just not 5x/minute
# forever. After two consecutive failed runs, back off for 30 minutes. That keeps
# the hotspot self-healing while cutting ICS churn by ~30x.
$script:CooldownFile = 'C:\home-server\state\hotspot-cooldown.json'
$script:CooldownMinutes = 30

function Get-UpstreamSignature {
    # Identifies WHAT we would be sharing. A cooldown is only meaningful for the
    # upstream that failed - if the upstream changes (most importantly, the USB modem
    # being plugged back in and enumerating as a Remote NDIS adapter), the previous
    # failures say nothing about the new one and must not suppress a retry.
    $rndis = @(Get-NetAdapter -ErrorAction SilentlyContinue |
               Where-Object { $_.InterfaceDescription -like 'Remote NDIS*' -and $_.Status -eq 'Up' }).Count
    $profileName = ''
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
        [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime] | Out-Null
        $ic = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if ($ic) { $profileName = $ic.ProfileName }
    } catch { }
    return ('rndis=' + $rndis + ';profile=' + $profileName)
}

function Test-TetheringAlreadyOn {
    # Cheap standalone check usable before the main WinRT block runs.
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
        [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime] | Out-Null
        [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime] | Out-Null
        $ic = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if (-not $ic) { return $false }
        $t = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($ic)
        return ($t.TetheringOperationalState -eq 'On')
    } catch { return $false }
}

$script:UpstreamSig = Get-UpstreamSignature

# --- SILENT-DROP VISIBILITY (added 2026-08-31) -------------------------------
# This script only ever logged when it detected Off and restarted - the drop
# ITSELF (tethering going Off between two 5-min ticks with the box otherwise
# idle) was never recorded, so root-causing why the radio drops was
# impossible after the fact. Log a state transition line every run, cheaply,
# before doing anything else. LastTetherStateFile persists just the state
# string across runs (separate from the cooldown/fail-count files).
$script:LastTetherStateFile = 'C:\home-server\state\last-tether-state.txt'
try {
    $prevState = if (Test-Path $script:LastTetherStateFile) { (Get-Content $script:LastTetherStateFile -Raw -ErrorAction SilentlyContinue).Trim() } else { $null }
    $curState = 'unknown'
    if (Test-TetheringAlreadyOn) { $curState = 'On' } else {
        try {
            Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
            [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime] | Out-Null
            [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime] | Out-Null
            $icNow = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
            if ($icNow) { $curState = [string]([Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($icNow)).TetheringOperationalState }
        } catch { $curState = 'unknown' }
    }
    if ($prevState -and $prevState -ne $curState) {
        Log ("STATE TRANSITION: tethering went '$prevState' -> '$curState' since last run (silent drop if this was Off and no repair ran between).")
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:LastTetherStateFile) -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Content -Path $script:LastTetherStateFile -Value $curState -Force -ErrorAction SilentlyContinue
} catch { }

# --- SINGLE-INSTANCE LOCK ----------------------------------------------------
#
# hotspot-start.ps1 invokes this 4x per run at 15s spacing, and AutoHotspotHealth
# fires every 60s, so two runs routinely overlap. Observed 2026-08-29: one instance
# calls StartTetheringAsync and the radio goes to InTransition, the other instance
# samples 'Off' a moment later and calls Start again, cancelling the first. The log
# shows the two interleaving and tethering never settles On. Serialise them.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\HomeServerHotspotStart')
$script:GotMutex = $false
try { $script:GotMutex = $script:Mutex.WaitOne(0) } catch { $script:GotMutex = $true }
if (-not $script:GotMutex) {
    Log "Hotspot start SKIPPED - another instance is already starting the hotspot."
    return
}

if (-not $script:InRepairRestart) {
    try {
        if (Test-Path $script:CooldownFile) {
            $cd = Get-Content $script:CooldownFile -Raw | ConvertFrom-Json
            if ($cd.untilUtc) {
                $until = [datetime]::Parse($cd.untilUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
                if ([datetime]::UtcNow -lt $until) {
                    # A cooldown with no recorded upstream (written by an older version
                    # of this script) carries no information about WHICH upstream
                    # failed, so it must not suppress a retry - fail open and re-test.
                    if ((-not $cd.upstreamSig) -or ($cd.upstreamSig -ne $script:UpstreamSig)) {
                        # Upstream changed (e.g. USB tethering came back) - the old
                        # failures are irrelevant, retry immediately instead of making
                        # the user wait out a cooldown earned by a different upstream.
                        Log ("Upstream CHANGED (was '" + $cd.upstreamSig + "', now '" + $script:UpstreamSig +
                             "') -> clearing cooldown and retrying now.")
                        Remove-Item $script:CooldownFile -Force -ErrorAction SilentlyContinue
                    } elseif (Test-TetheringAlreadyOn) {
                        # The hotspot is up despite the armed cooldown (someone started
                        # it by hand, or a retry succeeded after the file was written).
                        # Leaving the cooldown armed would suppress self-heal if the AP
                        # dropped later, and the success path that normally clears it is
                        # unreachable while we keep skipping. Clear it here.
                        Log "Tethering already On - clearing stale cooldown."
                        Remove-Item $script:CooldownFile -Force -ErrorAction SilentlyContinue
                    } else {
                        Log ("Hotspot start SKIPPED - in failure cooldown until " + $until.ToString('u') +
                             " (consecutive failures: " + $cd.failCount + ", upstream '" + $script:UpstreamSig +
                             "'). Avoiding ICS churn that breaks WSL networking.")
                        return
                    }
                }
            }
        }
    } catch { }
}

function Set-HotspotOutcome {
    param([bool]$Succeeded)
    try {
        $dir = Split-Path -Parent $script:CooldownFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ($Succeeded) {
            if (Test-Path $script:CooldownFile) { Remove-Item $script:CooldownFile -Force -ErrorAction SilentlyContinue }
            return
        }
        $fails = 0
        if (Test-Path $script:CooldownFile) {
            try { $fails = [int](Get-Content $script:CooldownFile -Raw | ConvertFrom-Json).failCount } catch { $fails = 0 }
        }
        $fails = $fails + 1
        $until = ''
        if ($fails -ge 2) {
            $until = [datetime]::UtcNow.AddMinutes($script:CooldownMinutes).ToString('o')
            Log ("Hotspot failed " + $fails + " runs in a row -> cooling down " + $script:CooldownMinutes + " min.")
        }
        [pscustomobject]@{
            failCount   = $fails
            untilUtc    = $until
            lastFailUtc = [datetime]::UtcNow.ToString('o')
            upstreamSig = $script:UpstreamSig
        } | ConvertTo-Json | Set-Content -Path $script:CooldownFile -Encoding utf8 -Force
    } catch { }
}

# Awaits a WinRT IAsyncOperation from PowerShell 5.1 and returns its result, so the
# operation's real Status is available instead of being silently discarded.
$script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

function Await-WinRt($WinRtTask, $ResultType) {
    try {
        $asTask = $script:AsTaskGeneric.MakeGenericMethod($ResultType)
        $netTask = $asTask.Invoke($null, @($WinRtTask))
        [void]$netTask.Wait(90000)
        return $netTask.Result
    } catch { return $null }
}

try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime] | Out-Null

    # 1) Wait up to ~90s for an internet-providing profile (modem warmup at boot).
    $targetProfile = $null
    for ($w = 0; $w -lt 30; $w++) {
        $allProfiles = [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles()
        foreach ($p in $allProfiles) {
            $level = $p.GetNetworkConnectivityLevel()
            if ($level -eq "InternetAccess" -and $p.ProfileName -ne "Tailscale") {
                $targetProfile = $p
                break
            }
        }
        if ($targetProfile) { Log "Internet profile: $($targetProfile.ProfileName)"; break }
        Start-Sleep -Seconds 3
    }

    if (-not $targetProfile) { Log "ERROR: No internet profile found after wait"; return }

    $tm = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($targetProfile)

    # Already on? DON'T blindly trust it. The radio reporting 'On' does NOT mean
    # clients have internet: the Mobile-Hotspot NAT public-side binding goes stale
    # when the USB modem re-enumerates, leaving clients associated-but-dead while
    # the radio stays On (and the box's own egress still works, masking it).
    # Verify the real client-path NAT; self-heal if it's down. (root cause 2026-06-22)
    # Skipped during a repair-triggered restart to avoid recursion (guard above).
    if ($tm.TetheringOperationalState -eq 'On' -and -not $script:InRepairRestart) {
        # 2026-06-26: use hysteresis wrapper so a SINGLE failed probe doesn't
        # trigger a full tether rebuild (was the root of 333 visible stop-restart
        # cycles in ~2 weeks). Wrapper returns $true on success OR a single
        # transient failure; $false only after 2 consecutive confirmed fails.
        if (Test-HotspotNatWithHysteresis -Log ${function:Log}) {
            Log "Tethering On and client-path NAT verified. Clients=$($tm.ClientCount)"
            return
        }
        Log "Tethering On but client-path NAT DEAD -> Repair-HotspotNat"
        $restart = { $env:HOTSPOT_REPAIR_RESTART = '1'; try { & $PSCommandPath } finally { $env:HOTSPOT_REPAIR_RESTART = $null } }
        $healed = Repair-HotspotNat -Log ${function:Log} -StartHotspot $restart
        Log "Repair-HotspotNat result: $healed"
        return
    }

    # Configure SSID/passphrase once.
    try {
        $config = $tm.GetCurrentAccessPointConfiguration()
        $config.Ssid = $(if ($env:HOTSPOT_SSID) { $env:HOTSPOT_SSID } else { "MyHotspot" })
        $config.Passphrase = $(if ($env:HOTSPOT_PASSPHRASE) { $env:HOTSPOT_PASSPHRASE } else { throw "Set $env:HOTSPOT_PASSPHRASE before running" })
        $tm.ConfigureAccessPointAsync($config) | Out-Null
        Start-Sleep -Seconds 3
    } catch { Log "Configure warn: $_" }

    # 2) Start + verify + retry until On.
    #
    # REWRITTEN 2026-08-29. The old loop was fire-and-forget: it never awaited
    # StartTetheringAsync, so the operation's actual Status was thrown away, and it
    # re-issued Start whenever the state was not 'On' - including while the state was
    # 'InTransition', which cancels the in-flight attempt. The observable result was
    # an endless Off -> InTransition -> Off oscillation with no reason ever logged.
    #
    # Awaiting the call gave the real answer immediately: Status = WiFiDeviceOff. The
    # Wi-Fi radio was wedged - `netsh` reported "Hardware On / Software On" and the
    # WinRT Radio API reported State=On, yet the adapter could see 0 networks and the
    # tethering stack considered the device off. `Restart-NetAdapter Wi-Fi` cured it
    # (3 networks visible again) and tethering then returned Success on first try.
    $on = $false
    $wifiResetTried = $false

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $conn = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
            if ($conn) { $tm = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($conn) }
        } catch {}

        if ($tm.TetheringOperationalState -eq 'On') { $on = $true; break }

        # NEVER issue Start while a transition is in flight - that is what cancels it.
        if ($tm.TetheringOperationalState -eq 'InTransition') {
            Log ("Attempt " + $attempt + ": state=InTransition -> waiting for it to settle (not re-issuing Start)")
            for ($k = 0; $k -lt 20; $k++) {
                Start-Sleep -Seconds 2
                if ($tm.TetheringOperationalState -eq 'On') { $on = $true; break }
                if ($tm.TetheringOperationalState -eq 'Off') { break }
            }
            if ($on) { break }
            continue
        }

        Log ("Attempt " + $attempt + ": state=Off -> StartTetheringAsync (awaited)")
        $status = ''
        try {
            $res = Await-WinRt $tm.StartTetheringAsync() ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
            if ($res) {
                $status = [string]$res.Status
                Log ("  result: " + $status + $(if ($res.AdditionalErrorMessage) { ' - ' + $res.AdditionalErrorMessage } else { '' }))
            }
        } catch { Log ("  Start warn: " + $_) }

        if ($status -eq 'Success') { $on = $true; break }

        # Self-heal the one failure mode that is both common and fixable here.
        if ($status -eq 'WiFiDeviceOff' -and -not $wifiResetTried) {
            $wifiResetTried = $true
            Log "  WiFiDeviceOff -> Wi-Fi radio is wedged; restarting the Wi-Fi adapter"
            try {
                Restart-NetAdapter -Name 'Wi-Fi' -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 20
                # Disable/enable drops the Wi-Fi Direct virtual adapters the AP needs;
                # a PnP rescan brings them back.
                & pnputil /scan-devices 2>&1 | Out-Null
                Start-Sleep -Seconds 6
                $visible = (netsh wlan show networks 2>&1 | Select-String 'networks currently visible') -join ''
                Log ("  after Wi-Fi reset: " + $visible.Trim())
            } catch { Log ("  Wi-Fi reset failed: " + $_) }
            continue
        }

        for ($k = 0; $k -lt 10; $k++) {
            Start-Sleep -Seconds 2
            if ($tm.TetheringOperationalState -eq 'On') { $on = $true; break }
        }
        if ($on) { break }
    }

    if ($on) {
        Log "Tethering On. Clients=$($tm.ClientCount)/$($tm.MaxClientCount)"
        $virtual = Get-NetAdapter | Where-Object { $_.Name -match "Local Area" } | Select-Object -First 1
        if ($virtual) { Log "Virtual adapter: $($virtual.Name) ($($virtual.Status)) MAC=$($virtual.MacAddress)" }
        # Re-apply TCP/QoS tuning to the freshly-(re)created hotspot adapter.
        Set-HotspotTcpTuning -Log ${function:Log}
        Set-HotspotOutcome -Succeeded $true
    } else {
        Log "ERROR: Tethering did not reach On after retries (state=$($tm.TetheringOperationalState))"
        Set-HotspotOutcome -Succeeded $false
    }
} catch {
    Log "ERROR: $_"
    Set-HotspotOutcome -Succeeded $false
} finally {
    if ($script:GotMutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        try { $script:Mutex.Dispose() } catch { }
    }
}

