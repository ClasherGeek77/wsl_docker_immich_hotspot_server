# immich-guard.ps1 - health probes + targeted repairs for the WSL/Docker/zrok/Immich stack.
#
# Design notes (2026-08-29):
#   The previous watchdog had exactly ONE repair action - `docker restart immich_zrok` -
#   and applied it to every failure. When the real fault was DNS it restarted the
#   container 3737 consecutive times over ~13 days and never recovered. This library
#   splits the stack into independently testable layers so a repair can be chosen to
#   match the actual broken layer, and every repair is verified before being called done.
#
#   Every WSL call goes through Invoke-WslBash, which enforces a hard timeout. The old
#   script called wsl.exe with no timeout at all; a wedged WSL VM would hang the
#   scheduled task forever and silently stop all health checking.

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$script:Distro        = 'Ubuntu-22.04'
$script:ZrokContainer = 'immich_zrok'
# the public url comes from ZROK_SHARE_NAME in immich\.env (override the file with IMMICH_ENV_FILE)
$script:ImmichEnvFile = if ($env:IMMICH_ENV_FILE) { $env:IMMICH_ENV_FILE } else { 'D:\home-server\immich\.env' }
$script:ZrokShare     = (Select-String -Path $script:ImmichEnvFile -Pattern '^ZROK_SHARE_NAME=(.+)$' -ErrorAction SilentlyContinue | Select-Object -First 1).Matches.Groups[1].Value.Trim()
$script:ZrokPublicUrl = "https://$($script:ZrokShare).share.zrok.io/api/server/ping"
$script:ComposeDir    = '/mnt/d/home-server/immich'
$script:ImmichLocal   = 'http://127.0.0.1:2283/api/server/ping'
$script:CoreContainers = @('immich_server', 'immich_postgres', 'immich_redis', 'immich_machine_learning', 'immich_zrok')
$script:PublicDns     = @('1.1.1.1', '8.8.8.8', '9.9.9.9')

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

function Invoke-WslBash {
    # Run a bash snippet as root inside WSL with a HARD timeout. Returns a hashtable
    # @{ Ok; Out; TimedOut }. A timeout kills the wsl.exe process so the caller can
    # keep going instead of hanging the whole scheduled task.
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [int]$TimeoutSec = 45
    )

    # Ship the snippet as base64 so quoting never has to survive the
    # PowerShell -> wsl.exe -> bash boundary intact.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    $inner = 'echo ' + $b64 + ' | base64 -d | bash'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = '-d ' + $script:Distro + ' -u root -- bash -c "' + $inner + '"'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # bash writes UTF-8; without this .NET decodes with the OEM code page and mangles output.
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    try {
        [void]$proc.Start()

        # Reads are .NET Tasks, NOT Register-ObjectEvent handlers.
        #
        # Two earlier attempts failed here and both failed SILENTLY, which is the
        # dangerous part - the watchdog reported healthy layers as broken:
        #   - BeginOutputReadLine + a fixed Start-Sleep dropped trailing lines, so
        #     `docker ps` looked short and running containers looked stopped.
        #   - BeginOutputReadLine + WaitForExit() returned output EMPTY, because a
        #     PowerShell event action cannot run while the runspace itself is blocked
        #     inside WaitForExit - the event pump never gets a turn.
        # ReadToEndAsync is pumped by the thread pool and is immune to both.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        $finished = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $finished) {
            try { $proc.Kill() } catch { }
            try { [void]$outTask.Wait(3000); [void]$errTask.Wait(3000) } catch { }
            return @{ Ok = $false; Out = 'TIMEOUT after ' + $TimeoutSec + 's'; TimedOut = $true }
        }

        try { [void]$outTask.Wait(5000) } catch { }
        try { [void]$errTask.Wait(5000) } catch { }

        $out = ''
        try { if ($outTask.IsCompleted -and -not $outTask.IsFaulted) { $out += $outTask.Result } } catch { }
        try { if ($errTask.IsCompleted -and -not $errTask.IsFaulted) { $out += $errTask.Result } } catch { }

        return @{ Ok = ($proc.ExitCode -eq 0); Out = $out.Trim(); TimedOut = $false }
    } catch {
        return @{ Ok = $false; Out = 'EXCEPTION: ' + $_.Exception.Message; TimedOut = $false }
    } finally {
        try { $proc.Dispose() } catch { }
    }
}

function Get-HttpStatus {
    # Windows-side HTTP probe. Deliberately NOT run through WSL: the public zrok URL
    # must be checked the way a real client sees it, and Windows DNS is a separate
    # path from the WSL resolver we are also trying to diagnose.
    param([string]$Url, [int]$TimeoutSec = 20)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return [int]$r.StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}

# ---------------------------------------------------------------------------
# Layer probes - cheapest and most fundamental first
# ---------------------------------------------------------------------------

function Test-KeepaliveAnchor {
    # L1: the scheduled task that holds the WSL VM open. Without it WSL tears the VM
    # down when no Linux session is attached, killing dockerd and every container.
    $t = Get-ScheduledTask -TaskName 'AutoStartWSL' -ErrorAction SilentlyContinue
    if (-not $t) { return @{ Ok = $false; Detail = 'AutoStartWSL task MISSING' } }
    if ($t.State -ne 'Running') { return @{ Ok = $false; Detail = 'AutoStartWSL state=' + $t.State } }
    return @{ Ok = $true; Detail = 'running' }
}

function Test-WslUp {
    # L2: is the distro actually running?
    $r = Invoke-WslBash -Command 'echo WSL_ALIVE' -TimeoutSec 30
    if ($r.TimedOut) { return @{ Ok = $false; Detail = 'WSL timeout' } }
    if ($r.Out -match 'WSL_ALIVE') { return @{ Ok = $true; Detail = 'alive' } }
    return @{ Ok = $false; Detail = 'no response: ' + $r.Out }
}

function Test-WslNetwork {
    # L2b: does the WSL VM have a network interface at all?
    #
    # THE failure that took the server down repeatedly. WSL2's network is an ICS-type
    # HNS network, and the hotspot's StartTetheringAsync storm churns the same ICS
    # stack. When they collide the WSL VM comes back with NO eth0: no address, no
    # default route, total isolation. Everything above this layer then looks
    # confusingly healthy - dockerd is active, all containers are Up, Immich answers
    # on localhost with HTTP 200 - while nothing can reach the internet and zrok 502s.
    # Without this probe the watchdog misdiagnoses it as a zrok problem and restarts
    # the tunnel forever, which is exactly what happened for 13 days.
    # Reachability is checked by IP, never by name, so this stays a pure network test
    # and does not blur into the DNS layer below it.
    #
    # Interface presence alone is NOT enough. Tearing down and rebuilding the HNS
    # network leaves the guest holding its old address and gateway while the
    # Windows-side vEthernet (WSL) adapter has no IPv4 at all - eth0 looks perfectly
    # healthy, has a default route, and routes precisely nowhere. Only an actual
    # egress probe distinguishes that from a working network.
    $bash = @'
IP=$(ip -4 addr show eth0 2>/dev/null | grep -c "inet ")
RT=$(ip route 2>/dev/null | grep -c "^default")
EG=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://1.1.1.1/ 2>/dev/null || echo 000)
echo "IP=$IP RT=$RT EG=$EG"
'@
    $r = Invoke-WslBash -Command $bash -TimeoutSec 35
    if ($r.Out -notmatch 'IP=(\d+)\s+RT=(\d+)\s+EG=(\d+)') { return @{ Ok = $false; Detail = 'probe unreadable: ' + $r.Out } }
    $hasIp = [int]$Matches[1] -ge 1
    $hasRoute = [int]$Matches[2] -ge 1
    $egress = [int]$Matches[3]

    if ($hasIp -and $hasRoute -and $egress -ne 0) { return @{ Ok = $true; Detail = 'eth0 up, route ok, egress ' + $egress } }

    # 2026-08-31: hotspot Off->On churn wedges icssvc for a few seconds at a
    # time, which shows up here as a transient egress dip even when the
    # network self-heals within the minute. Retry once before declaring this
    # layer broken and kicking off Repair-WslNetwork (which is disruptive -
    # it pauses the hotspot task and bounces the VM).
    Start-Sleep -Seconds 5
    $r2 = Invoke-WslBash -Command $bash -TimeoutSec 35
    if ($r2.Out -match 'IP=(\d+)\s+RT=(\d+)\s+EG=(\d+)') {
        $hasIp2 = [int]$Matches[1] -ge 1; $hasRoute2 = [int]$Matches[2] -ge 1; $egress2 = [int]$Matches[3]
        if ($hasIp2 -and $hasRoute2 -and $egress2 -ne 0) {
            return @{ Ok = $true; Detail = 'eth0 up, route ok, egress ' + $egress2 + ' (recovered on retry)' }
        }
    }

    if (-not $hasIp) { return @{ Ok = $false; Detail = 'eth0 MISSING (WSL VM has no NIC)' } }
    if (-not $hasRoute) { return @{ Ok = $false; Detail = 'eth0 present but no default route' } }
    return @{ Ok = $false; Detail = 'eth0 up but NO EGRESS (stale gateway - host side has no IPv4)' }
}

function Test-Dockerd {
    # L3: docker daemon.
    $r = Invoke-WslBash -Command 'systemctl is-active docker 2>/dev/null || echo down' -TimeoutSec 30
    if ($r.Out -match 'active') { return @{ Ok = $true; Detail = 'active' } }
    return @{ Ok = $false; Detail = $r.Out }
}

function Test-WslDns {
    # L4: can the WSL host resolve public names? This is the check the old watchdog
    # never had, and it is exactly the layer that was broken for ~13 days: WSL's
    # generated resolv.conf points at a Windows-side DNS proxy on the vEthernet
    # gateway, which goes dead when the USB LTE modem re-enumerates.
    $r = Invoke-WslBash -Command 'getent hosts api-v1.zrok.io >/dev/null 2>&1 && echo DNS_OK || echo DNS_FAIL' -TimeoutSec 30
    if ($r.Out -match 'DNS_OK') { return @{ Ok = $true; Detail = 'resolves' } }
    return @{ Ok = $false; Detail = 'cannot resolve api-v1.zrok.io' }
}

function Test-ContainerDns {
    # L5: can a container resolve through Docker's embedded resolver (127.0.0.11)?
    # zrok dies here specifically - it needs api-v1.zrok.io to build its Ziti session.
    # Probed from inside the running zrok container so no image pull is required
    # (pulling would itself need the DNS we are testing).
    $cmd = 'docker exec ' + $script:ZrokContainer + ' getent hosts api-v1.zrok.io >/dev/null 2>&1 && echo CDNS_OK || echo CDNS_FAIL'
    $r = Invoke-WslBash -Command $cmd -TimeoutSec 40
    if ($r.Out -match 'CDNS_OK') { return @{ Ok = $true; Detail = 'resolves' } }
    return @{ Ok = $false; Detail = 'container cannot resolve api-v1.zrok.io' }
}

function Test-ImmichLocal {
    # L6: Immich itself, bypassing the tunnel entirely. Separates "Immich is broken"
    # from "the tunnel to a healthy Immich is broken" - two very different repairs.
    $cmd = "curl -s -o /dev/null -w '%{http_code}' --max-time 12 " + $script:ImmichLocal
    $r = Invoke-WslBash -Command $cmd -TimeoutSec 30
    if ($r.Out -match '200') { return @{ Ok = $true; Detail = 'HTTP 200' } }
    return @{ Ok = $false; Detail = 'HTTP ' + $r.Out }
}

function Test-ZrokPublic {
    # L7: what the outside world sees.
    #
    # 2026-08-31: hotspot's tethering Off->On cycling wedges icssvc for a few
    # seconds at a time even when it self-heals within the minute. A single
    # probe landing in that window reports the whole stack unhealthy and can
    # trigger an unnecessary tier-1 repair. Retry once, 5s apart - same
    # transient-tolerant shape as Test-HotspotNatWithHysteresis - before
    # calling this layer broken.
    $code = Get-HttpStatus -Url $script:ZrokPublicUrl -TimeoutSec 20
    if ($code -eq 200) { return @{ Ok = $true; Detail = 'HTTP 200' } }
    Start-Sleep -Seconds 5
    $code2 = Get-HttpStatus -Url $script:ZrokPublicUrl -TimeoutSec 20
    if ($code2 -eq 200) { return @{ Ok = $true; Detail = 'HTTP 200 (recovered on retry, first was ' + $code + ')' } }
    return @{ Ok = $false; Detail = 'HTTP ' + $code + ' then ' + $code2 }
}

function Test-ContainerRoster {
    # L8: every core container present and Up.
    #
    # Confirmed twice before reporting a container down. A truncated or empty
    # `docker ps` read is indistinguishable from a genuinely stopped container, and
    # acting on the difference means restarting containers that were never broken.
    # Cheap to re-read; expensive to get wrong.
    $missing = @()
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $r = Invoke-WslBash -Command "docker ps --format '{{.Names}}'" -TimeoutSec 40
        $running = @()
        if ($r.Out) { $running = $r.Out -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }

        $missing = @()
        foreach ($c in $script:CoreContainers) { if ($running -notcontains $c) { $missing += $c } }

        if ($missing.Count -eq 0) {
            return @{ Ok = $true; Detail = 'all ' + $script:CoreContainers.Count + ' up'; Missing = @() }
        }
        if ($attempt -eq 1) { Start-Sleep -Seconds 3 }
    }
    return @{ Ok = $false; Detail = 'down: ' + ($missing -join ','); Missing = $missing }
}

# ---------------------------------------------------------------------------
# Repairs - each one targets a specific layer and is verified by its caller
# ---------------------------------------------------------------------------

function Repair-WslDns {
    # Re-pin the WSL resolver to public DNS and make it stick.
    #
    # Three things have to be true, because they fail independently:
    #   1. /etc/resolv.conf points at working resolvers RIGHT NOW (immediate effect).
    #   2. /etc/wsl.conf has generateResolvConf=false so WSL stops overwriting it
    #      (only takes effect after the VM restarts - hence #3 as the safety net).
    #   3. /etc/docker/daemon.json pins container DNS, so the embedded resolver at
    #      127.0.0.11 forwards to public DNS regardless of what the host resolv.conf
    #      currently says. This is what actually keeps zrok alive between VM restarts.
    $bash = @'
set -u
CHANGED=0

# 1. resolv.conf - replace WSL's symlink with a real file and make it IMMUTABLE.
#
#    WSL recreates /etc/resolv.conf as a symlink to /mnt/wsl/resolv.conf and refills
#    it with the Windows-side DNS proxy address. Writing a plain file here is undone
#    within seconds. generateResolvConf=false in /etc/wsl.conf fixes it properly but
#    only takes effect on the next VM boot, which would mean an outage now. chattr +i
#    makes the fix durable immediately and with zero downtime: WSL's rewrite fails
#    and leaves the pinned resolvers in place.
if ! grep -q '1.1.1.1' /etc/resolv.conf 2>/dev/null; then
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
  printf '%s\n' '# Pinned by home-server watchdog (immutable): the WSL-generated DNS proxy dies' > /etc/resolv.conf
  printf '%s\n' '# when the USB LTE modem re-enumerates, which silently killed zrok for 13 days.' >> /etc/resolv.conf
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\noptions timeout:2 attempts:2 rotate\n' >> /etc/resolv.conf
  chmod 644 /etc/resolv.conf
  CHANGED=1
  echo "resolv.conf re-pinned"
fi
# Re-assert immutability every run - it is lost if the file is ever recreated.
chattr +i /etc/resolv.conf 2>/dev/null && echo "resolv.conf immutable" || echo "chattr unsupported (fs)"

# 2. wsl.conf - stop WSL regenerating it on the next VM boot.
if ! grep -q 'generateResolvConf' /etc/wsl.conf 2>/dev/null; then
  printf '\n[network]\ngenerateResolvConf = false\n' >> /etc/wsl.conf
  CHANGED=1
  echo "wsl.conf generateResolvConf=false added"
fi

# 3. daemon.json - pin container DNS (survives resolv.conf being clobbered).
if ! grep -q '"dns"' /etc/docker/daemon.json 2>/dev/null; then
  cp -a /etc/docker/daemon.json /etc/docker/daemon.json.bak-$(date +%s) 2>/dev/null || true
  printf '{\n  "live-restore": true,\n  "dns": ["1.1.1.1", "8.8.8.8", "9.9.9.9"]\n}\n' > /etc/docker/daemon.json
  CHANGED=1
  echo "daemon.json dns pinned (needs dockerd restart to apply)"
fi

echo "CHANGED=$CHANGED"
getent hosts api-v1.zrok.io >/dev/null 2>&1 && echo "DNS_NOW_OK" || echo "DNS_STILL_FAIL"
'@
    $r = Invoke-WslBash -Command $bash -TimeoutSec 60
    return @{ Ok = ($r.Out -match 'DNS_NOW_OK'); Detail = ($r.Out -replace '\r?\n', '; ') }
}

function Repair-ZrokRestart {
    $r = Invoke-WslBash -Command ('docker restart ' + $script:ZrokContainer + ' 2>&1') -TimeoutSec 90
    return @{ Ok = $r.Ok; Detail = $r.Out }
}

function Get-ComposePrelude {
    # The compose plugin on this box (v5.1.0) negotiates Docker API v1.53, but the
    # installed dockerd only supports up to v1.41, so every compose command fails with
    #   "client version 1.53 is too new. Maximum supported API version is 1.41"
    # and the docker-compose v1 fallback (1.25.1) is too old to parse the compose file
    # ("Unsupported config option ... 'mem_limit'"). That combination meant EVERY
    # compose-based repair was dead on arrival - found by fault injection, not in prod.
    #
    # Pinning DOCKER_API_VERSION to whatever the daemon actually reports fixes it, and
    # reading it at runtime means a future docker upgrade does not re-break this.
    return @'
API=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null)
if [ -n "$API" ]; then export DOCKER_API_VERSION="$API"; fi
'@
}

function Repair-ZrokRecreate {
    # A plain restart keeps the container's original /etc/resolv.conf and its stale
    # Ziti session, and does not re-attach a network it was detached from. Recreating
    # rebuilds all of that from current daemon config.
    # --no-deps is REQUIRED: without it --force-recreate cascades through depends_on
    # and also recreates immich_postgres and immich_redis. Bouncing the database to
    # fix a tunnel is both unnecessary and riskier than the fault being repaired.
    $cmd = (Get-ComposePrelude) + "`ncd " + $script:ComposeDir + ' && docker compose up -d --force-recreate --no-deps zrok 2>&1'
    $r = Invoke-WslBash -Command $cmd -TimeoutSec 180
    return @{ Ok = $r.Ok; Detail = ($r.Out -replace '\r?\n', '; ') }
}

function Repair-ComposeUp {
    # Bring back any missing containers without touching healthy ones.
    $cmd = (Get-ComposePrelude) + "`ncd " + $script:ComposeDir + ' && docker compose up -d 2>&1'
    $r = Invoke-WslBash -Command $cmd -TimeoutSec 240
    return @{ Ok = $r.Ok; Detail = ($r.Out -replace '\r?\n', '; ') }
}

function Repair-Dockerd {
    # live-restore keeps containers running across a daemon restart, and this is also
    # what makes a daemon.json DNS change take effect.
    $bash = @'
systemctl restart docker 2>&1 || (rm -f /var/run/docker.pid; setsid nohup dockerd >/var/log/dockerd-fallback.log 2>&1 </dev/null & disown)
sleep 8
systemctl is-active docker 2>/dev/null || echo down
'@
    $r = Invoke-WslBash -Command $bash -TimeoutSec 120
    return @{ Ok = ($r.Out -match 'active'); Detail = $r.Out }
}

function Repair-WslRestart {
    # Heaviest repair short of a reboot: bounce the whole WSL VM. This is what makes
    # generateResolvConf=false authoritative. Containers are restart:always so they
    # come back on their own once dockerd is up; the anchor task re-holds the VM.
    param([scriptblock]$Log = { param($m) })
    & $Log 'Repair-WslRestart: wsl --shutdown'
    Start-Process -FilePath 'wsl.exe' -ArgumentList '--shutdown' -Wait -NoNewWindow -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10

    $anchor = Get-ScheduledTask -TaskName 'AutoStartWSL' -ErrorAction SilentlyContinue
    if ($anchor) {
        if ($anchor.State -eq 'Running') { Stop-ScheduledTask -TaskName 'AutoStartWSL' -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3 }
        Start-ScheduledTask -TaskName 'AutoStartWSL' -ErrorAction SilentlyContinue
        & $Log 'Repair-WslRestart: AutoStartWSL restarted'
    }

    # Wait for dockerd to come back rather than assuming a fixed sleep is enough.
    $dockerOk = $false
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Seconds 10
        $d = Test-Dockerd
        if ($d.Ok) {
            & $Log ('Repair-WslRestart: dockerd active after ' + (($i + 1) * 10) + 's')
            $dockerOk = $true
            break
        }
    }
    if (-not $dockerOk) { return @{ Ok = $false; Detail = 'dockerd did not come back within 240s' } }

    # dockerd being up is NOT sufficient. A WSL VM that lost its NIC still runs
    # dockerd and all containers perfectly happily - this repair originally reported
    # success while the box had no network at all. Require eth0, and if it is missing
    # escalate to the network rebuild, which is the only thing that fixes it.
    $net = Test-WslNetwork
    if ($net.Ok) { return @{ Ok = $true; Detail = 'dockerd active, eth0 up' } }

    & $Log ('Repair-WslRestart: dockerd up but network broken (' + $net.Detail + ') -> Repair-WslNetwork')
    $fix = Repair-WslNetwork -Log $Log
    return @{ Ok = $fix.Ok; Detail = 'via Repair-WslNetwork: ' + $fix.Detail }
}

function Repair-WslNetwork {
    # Rebuild WSL's virtual NIC after the hotspot's ICS churn destroys it.
    #
    # Order matters and was established by hand on 2026-08-29:
    #   1. Stop the hotspot health task FIRST. While it is running its retry storm,
    #      WSL cannot create its ICS network and every rebuild attempt fails. This is
    #      why plain `wsl --shutdown` twice, a WslService restart, and a vEthernet
    #      adapter bounce all failed - the storm just re-broke it each time.
    #   2. Shut the VM down and drop any stale HNS "WSL" network so it is rebuilt
    #      from scratch rather than reattached in its broken state.
    #   3. Bring WSL back and WAIT FOR eth0 - not for dockerd, which comes up happily
    #      on a network-less VM and makes the box look healthy when it is not.
    # The hotspot task is re-enabled in finally{} so a failure here never leaves the
    # hotspot permanently off.
    param([scriptblock]$Log = { param($m) })

    $hotspotTask = 'AutoHotspotHealth'
    try {
        & $Log 'Repair-WslNetwork: pausing AutoHotspotHealth (its ICS churn blocks WSL network creation)'
        Disable-ScheduledTask -TaskName $hotspotTask -ErrorAction SilentlyContinue | Out-Null
        $hs = Get-ScheduledTask -TaskName $hotspotTask -ErrorAction SilentlyContinue
        if ($hs -and $hs.State -eq 'Running') { Stop-ScheduledTask -TaskName $hotspotTask -ErrorAction SilentlyContinue }
        # Kill any already-running hotspot script instance; disabling the task does
        # not stop a run that is already in its retry loop.
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'hotspot-start' } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
        Start-Sleep -Seconds 3

        # Stop the keepalive anchor BEFORE tearing the VM down.
        #
        # This ordering is the difference between the repair working and silently
        # producing a broken VM. AutoStartWSL holds a foreground `wsl ... sleep` loop
        # whose whole job is to restart WSL the moment it goes away - so with the
        # anchor still running, `wsl --shutdown` is undone within a second and the VM
        # comes back up in the middle of the ICS bounce, before icssvc can build the
        # HNS network. The result is a VM with eth0 present, a default route, and no
        # egress at all, which then survives the rest of the repair untouched.
        & $Log 'Repair-WslNetwork: stopping AutoStartWSL anchor so the VM stays down during the rebuild'
        $anchorTask = Get-ScheduledTask -TaskName 'AutoStartWSL' -ErrorAction SilentlyContinue
        if ($anchorTask -and $anchorTask.State -eq 'Running') { Stop-ScheduledTask -TaskName 'AutoStartWSL' -ErrorAction SilentlyContinue }
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'wsl-up|keepalive-anchor' } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
        Start-Sleep -Seconds 3

        & $Log 'Repair-WslNetwork: wsl --shutdown'
        Start-Process -FilePath 'wsl.exe' -ArgumentList '--shutdown' -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10

        # Drop the stale HNS network so WSL rebuilds it.
        if (Get-Command Get-HnsNetwork -ErrorAction SilentlyContinue) {
            try {
                Get-HnsNetwork | Where-Object { $_.Name -eq 'WSL' } | ForEach-Object {
                    Remove-HnsNetwork $_
                    & $Log ('Repair-WslNetwork: removed stale HNS network ' + $_.Id)
                }
            } catch { & $Log ('Repair-WslNetwork: HNS removal failed: ' + $_.Exception.Message) }
            Start-Sleep -Seconds 5
        }

        # THE step that actually fixes it. The WSL HNS network is Type=ICS, so it is
        # created and owned by the Internet Connection Sharing services. When icssvc
        # ends up Stopped - which is what the hotspot's tethering storm does to it -
        # WSL simply cannot build its network: the VM boots with no usable NIC and
        # `wsl --shutdown` on its own will never fix it, no matter how many times it
        # is repeated. Verified 2026-08-29: icssvc was Stopped, starting it brought
        # eth0 back with egress within 10s.
        #
        # sc.exe rather than Restart-Service because Restart-Service -Force reported
        # "stop failed" on this box while sc.exe drives the same transition cleanly.
        # Stop/start rather than Restart-Service, and let each transition SETTLE.
        # These waits are not padding - the sequence below is the one verified to
        # rebuild the network on this box; shorter gaps left the services half-up and
        # WSL then booted without a network.
        & $Log 'Repair-WslNetwork: bouncing ICS services (icssvc owns the WSL HNS network)'
        try { & sc.exe stop SharedAccess | Out-Null } catch { }
        Start-Sleep -Seconds 4
        try { & sc.exe stop icssvc | Out-Null } catch { }
        Start-Sleep -Seconds 4
        # icssvc MUST actually reach Running before we boot WSL. Observed 2026-08-29:
        # a single `sc.exe start` left it Stopped, WSL came up with a network that then
        # collapsed ~75s later, and the watchdog escalated in a loop. Starting it is not
        # the same as it having started - verify and retry.
        $icsOk = $false
        for ($a = 1; $a -le 4; $a++) {
            try { & sc.exe start icssvc | Out-Null } catch { }
            Start-Sleep -Seconds 6
            if ((Get-Service icssvc -ErrorAction SilentlyContinue).Status -eq 'Running') { $icsOk = $true; break }
            & $Log ("Repair-WslNetwork: icssvc still not Running (attempt $a), retrying")
        }
        try { & sc.exe start SharedAccess | Out-Null } catch { }
        Start-Sleep -Seconds 8
        & $Log ('Repair-WslNetwork: icssvc now ' + (Get-Service icssvc -ErrorAction SilentlyContinue).Status +
                $(if (-not $icsOk) { ' (WARNING: never confirmed Running - network will likely collapse again)' } else { '' }))

        # Boot the VM ONCE, directly, now that ICS is settled - this is what triggers
        # HNS to build a fresh WSL network - and only then hand back to the anchor.
        & $Log 'Repair-WslNetwork: booting WSL once with ICS settled'
        try { & wsl.exe -d $script:Distro -u root -- bash -c 'sleep 3; true' 2>&1 | Out-Null } catch { }
        Start-Sleep -Seconds 8

        $anchor = Get-ScheduledTask -TaskName 'AutoStartWSL' -ErrorAction SilentlyContinue
        if ($anchor) { Start-ScheduledTask -TaskName 'AutoStartWSL' -ErrorAction SilentlyContinue }

        for ($i = 0; $i -lt 15; $i++) {
            $net = Test-WslNetwork
            if ($net.Ok) {
                & $Log ('Repair-WslNetwork: network restored after ' + (($i + 1) * 10) + 's (' + $net.Detail + ')')
                return @{ Ok = $true; Detail = $net.Detail }
            }
            Start-Sleep -Seconds 10
        }
        return @{ Ok = $false; Detail = 'network did not come back within 150s' }
    } catch {
        return @{ Ok = $false; Detail = 'EXCEPTION: ' + $_.Exception.Message }
    } finally {
        # Re-enable AND actively restart the AP - do not just hand it back to the task.
        #
        # Two things go wrong otherwise, and both were observed on 2026-08-29:
        #  1. The ICS bounce above DESTROYS the Wi-Fi Direct virtual adapter, so the
        #     hotspot is down when this repair finishes even though nothing "failed".
        #  2. finally{} does not run if the process is killed mid-repair (e.g. the box
        #     drops off the network). The task was then left Disabled with the adapter
        #     already gone, so the AP stayed down with nothing able to recover it.
        # Clearing the cooldown matters too: failures recorded against the pre-bounce
        # adapter must not suppress the restart attempt now.
        # Respect the deliberate opt-out here too. This finally{} was the second place
        # that re-enabled the hotspot behind the operator's back: the flag stopped
        # Ensure-HotspotTaskEnabled, but a repair still turned the AP back on.
        # NB: no `return` in here - PowerShell forbids flow control leaving a finally
        # block ("Flow of control cannot leave a Finally block"), so this is an if/else.
        $hotspotOptOut = Test-Path 'C:\home-server\state\HOTSPOT_DISABLED'
        if ($hotspotOptOut) {
            & $Log 'Repair-WslNetwork: leaving AutoHotspotHealth disabled (HOTSPOT_DISABLED flag set)'
        } else {
            Enable-ScheduledTask -TaskName $hotspotTask -ErrorAction SilentlyContinue | Out-Null
            & $Log 'Repair-WslNetwork: AutoHotspotHealth re-enabled'
        }
        # ONLY restart the AP if it is actually down.
        #
        # Starting tethering re-binds ICS, and ICS is what owns the WSL network we just
        # spent two minutes rebuilding. Restarting unconditionally created a feedback
        # loop on 2026-08-29: repair succeeds -> hotspot restart churns ICS -> WSL
        # network dies ~75s later -> repair again. If tethering is already On there is
        # nothing to fix and every extra StartTetheringAsync is pure risk.
        try {
            $tethering = 'unknown'
            try {
                Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
                [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime] | Out-Null
                [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime] | Out-Null
                $icp = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
                if ($icp) {
                    $tm = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($icp)
                    $tethering = [string]$tm.TetheringOperationalState
                }
            } catch { }

            if ($hotspotOptOut) {
                & $Log 'Repair-WslNetwork: hotspot restart SKIPPED (HOTSPOT_DISABLED flag set)'
            } elseif ($tethering -eq 'On') {
                & $Log 'Repair-WslNetwork: hotspot already On - NOT restarting (avoids re-churning ICS)'
            } else {
                Remove-Item 'C:\home-server\state\hotspot-cooldown.json' -Force -ErrorAction SilentlyContinue
                $starter = 'C:\home-server\runtime\hotspot-start-core.ps1'
                if (Test-Path $starter) {
                    & $starter | Out-Null
                    & $Log ("Repair-WslNetwork: hotspot was '$tethering' -> restart invoked (ICS bounce destroys the Wi-Fi Direct adapter)")
                }
            }
        } catch { & $Log ('Repair-WslNetwork: hotspot restart failed: ' + $_.Exception.Message) }
    }
}

function Ensure-IcsService {
    # Cheap PREVENTIVE check, run every cycle before anything else.
    #
    # icssvc going Stopped is the single upstream trigger for the whole outage chain:
    # icssvc stops -> WSL cannot build its ICS-type HNS network -> the VM loses eth0
    # -> containers lose the internet -> zrok 502s while Immich still answers on
    # localhost. Starting a stopped service costs milliseconds; recovering from the
    # NIC-less state costs a full WSL rebuild. Catch it here instead.
    param([scriptblock]$Log = { param($m) })
    try {
        $svc = Get-Service icssvc -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            & $Log ('Ensure-IcsService: icssvc is ' + $svc.Status + ' -> starting (it owns the WSL network)')
            & sc.exe start icssvc | Out-Null
            Start-Sleep -Seconds 3
            $svc = Get-Service icssvc -ErrorAction SilentlyContinue
            & $Log ('Ensure-IcsService: icssvc now ' + $svc.Status)
            return @{ Ok = ($svc.Status -eq 'Running'); Detail = 'restarted' }
        }
        return @{ Ok = $true; Detail = 'running' }
    } catch {
        return @{ Ok = $false; Detail = $_.Exception.Message }
    }
}

function Ensure-HotspotTaskEnabled {
    # Backstop for a repair that died before its finally{} could run.
    #
    # Repair-WslNetwork deliberately disables AutoHotspotHealth while it rebuilds the
    # WSL network. If that repair is killed partway - which happens, because the repair
    # itself can knock the box off the network - the task is left Disabled and the AP
    # never comes back, since the ICS bounce already destroyed the Wi-Fi Direct adapter.
    # A disabled hotspot task is never correct at rest, so re-enable it unconditionally.
    param([scriptblock]$Log = { param($m) })
    try {
        # Deliberate opt-out beats the backstop.
        #
        # This function cannot tell "disabled by an interrupted repair" from "disabled
        # on purpose", and on 2026-08-29 it re-enabled a hotspot that had been switched
        # off deliberately to keep Immich reachable - then the AP restart churned ICS
        # and triggered three rounds of L2b_wslnet repairs. An explicit flag file is the
        # operator saying "I meant it", and must win.
        if (Test-Path 'C:\home-server\state\HOTSPOT_DISABLED') {
            return @{ Ok = $true; Detail = 'left disabled (HOTSPOT_DISABLED flag set)' }
        }
        $t = Get-ScheduledTask -TaskName 'AutoHotspotHealth' -ErrorAction SilentlyContinue
        if (-not $t) { return @{ Ok = $false; Detail = 'AutoHotspotHealth task missing' } }
        if ($t.State -eq 'Disabled') {
            & $Log 'Ensure-HotspotTaskEnabled: AutoHotspotHealth was Disabled -> re-enabling (leftover from an interrupted repair)'
            Enable-ScheduledTask -TaskName 'AutoHotspotHealth' -ErrorAction SilentlyContinue | Out-Null
            # The AP is almost certainly down too; clear the cooldown so the task's next
            # run is allowed to actually start it.
            Remove-Item 'C:\home-server\state\hotspot-cooldown.json' -Force -ErrorAction SilentlyContinue
            return @{ Ok = $true; Detail = 're-enabled'; Repaired = $true }
        }
        return @{ Ok = $true; Detail = $t.State }
    } catch { return @{ Ok = $false; Detail = $_.Exception.Message } }
}

function Ensure-PortProxy {
    # Keep the LAN path alive: 0.0.0.0:2283 -> <WSL eth0>:2283
    #
    # The phone uploads to http://192.168.137.1:2283 (the hotspot gateway), which only
    # reaches Immich because of a netsh portproxy rule forwarding to the WSL VM. That
    # rule stores the VM's IP LITERALLY, and WSL can hand out a different IP on any
    # restart. When it changes, the rule silently points at nothing and the whole LAN
    # path dies with "connection refused" - while zrok keeps working, so every
    # server-side health signal still looks green. Nothing else in the watchdog would
    # catch it.
    #
    # Treated as a preventive fixer rather than an escalation-ladder layer: there is
    # exactly one correct repair, so tiers would add nothing, and the ladder's success
    # check (zrok reachable) is unrelated to whether this rule is right.
    param([scriptblock]$Log = { param($m) }, [int]$Port = 2283)

    try {
        $r = Invoke-WslBash -Command "ip -4 -o addr show eth0 2>/dev/null | awk '{print `$4}' | cut -d/ -f1" -TimeoutSec 30
        $wslIp = @($r.Out -split '\r?\n' | ForEach-Object { $_.Trim() } |
                   Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })[0]
        if (-not $wslIp) { return @{ Ok = $false; Detail = 'WSL eth0 IP unreadable (VM down?)' } }

        # netsh table rows look like:  0.0.0.0   2283   172.25.0.144   2283
        $current = $null
        foreach ($line in (& netsh interface portproxy show v4tov4 2>&1)) {
            if ("$line" -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s+(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s*$') {
                if ([int]$Matches[2] -eq $Port) { $current = $Matches[3] }
            }
        }

        if ($current -eq $wslIp) { return @{ Ok = $true; Detail = "0.0.0.0:$Port -> ${wslIp}:$Port" } }

        $was = if ($current) { $current } else { '<missing>' }
        & $Log ("Ensure-PortProxy: rule points at $was but WSL is $wslIp -> rewriting")
        if ($current) {
            & netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 2>&1 | Out-Null
        }
        & netsh interface portproxy add v4tov4 listenport=$Port listenaddress=0.0.0.0 `
              connectport=$Port connectaddress=$wslIp 2>&1 | Out-Null

        # Confirm it took, rather than trusting the add succeeded.
        $verified = $null
        foreach ($line in (& netsh interface portproxy show v4tov4 2>&1)) {
            if ("$line" -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s+(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s*$') {
                if ([int]$Matches[2] -eq $Port) { $verified = $Matches[3] }
            }
        }
        if ($verified -eq $wslIp) {
            return @{ Ok = $true; Detail = "repaired: $was -> $wslIp"; Repaired = $true }
        }
        return @{ Ok = $false; Detail = "rewrite FAILED (still '$verified', wanted $wslIp)" }
    } catch {
        return @{ Ok = $false; Detail = 'EXCEPTION: ' + $_.Exception.Message }
    }
}

function Ensure-UpstreamMetrics {
    # Keep the upstream choice STABLE, and make it survive the move to a LAN cable.
    #
    # With more than one upstream present (USB tether + Wi-Fi today, LAN cable +
    # Wi-Fi later), Windows re-picks the internet connection profile whenever link
    # state wobbles. Every re-pick re-binds ICS, and the WSL network is an ICS
    # network, so it is destroyed. Pinning metrics stops the oscillation.
    #
    # CRITICAL GUARD: only ever prefer a wired interface that ACTUALLY HAS INTERNET.
    # Setting a low metric on a wired link that is up but dead blackholes traffic and
    # takes the whole box off the network - which is exactly what happened on
    # 2026-08-29 when the USB tether was Up but had already stopped passing traffic.
    param([scriptblock]$Log = { param($m) })
    try {
        $changed = @()

        # Classify every real (non-virtual) Up adapter by whether it ACTUALLY has
        # internet, not merely whether it has a link.
        $cands = @()
        foreach ($a in (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and -not $_.Virtual })) {
            $prof = Get-NetConnectionProfile -InterfaceAlias $a.Name -ErrorAction SilentlyContinue
            $hasNet = ($prof -and $prof.IPv4Connectivity -eq 'Internet')
            $isWifi = ($a.Name -eq 'Wi-Fi' -or $a.InterfaceDescription -like '*Wireless*')
            $cands += [pscustomobject]@{ Name = $a.Name; HasNet = $hasNet; IsWifi = $isWifi }
        }

        $withNet = @($cands | Where-Object { $_.HasNet })
        # NEVER demote when nothing has internet - that would just shuffle a broken
        # setup and could strand the box. Only act when there is a known-good upstream
        # to prefer.
        if ($withNet.Count -eq 0) {
            return @{ Ok = $true; Detail = 'no interface has internet - leaving metrics alone' }
        }

        foreach ($c in $cands) {
            # A link that is Up but has NO internet must never win the default route.
            # This is the exact failure seen on 2026-08-29: a USB modem with no service
            # was plugged in, Windows still routed through it, and the whole box went
            # dark (Tailscale + zrok both unreachable) until it was physically removed.
            # 9999 keeps it usable if explicitly addressed, but never as the default.
            $want = if (-not $c.HasNet) { 9999 } elseif ($c.IsWifi) { 50 } else { 5 }
            $cur = Get-NetIPInterface -InterfaceAlias $c.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($cur -and $cur.InterfaceMetric -ne $want) {
                Set-NetIPInterface -InterfaceAlias $c.Name -AddressFamily IPv4 -InterfaceMetric $want -ErrorAction SilentlyContinue
                $changed += ($c.Name + '->' + $want + $(if (-not $c.HasNet) { '(no-internet)' } else { '' }))
            }
        }

        if ($changed.Count -gt 0) { & $Log ('Ensure-UpstreamMetrics: ' + ($changed -join ', ')) }
        return @{ Ok = $true; Detail = $(if ($changed.Count) { $changed -join ',' } else { 'unchanged' }) }
    } catch {
        return @{ Ok = $false; Detail = $_.Exception.Message }
    }
}

function Repair-ContainerStart {
    param([string[]]$Names)
    $joined = ($Names -join ' ')
    $r = Invoke-WslBash -Command ('docker start ' + $joined + ' 2>&1') -TimeoutSec 120
    return @{ Ok = $r.Ok; Detail = $r.Out }
}
