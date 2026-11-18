# hotspot-nat-guard.ps1 - end-to-end NAT verification + aggressive self-heal.
#
# WHY THIS EXISTS (root cause, 2026-06-22):
# This box shares internet via the MODERN Mobile Hotspot stack
# (NetworkOperatorTetheringManager / WlanSvc / icssvc), NOT legacy ICS COM
# sharing and NOT the legacy hosted-network SoftAP. Mobile Hotspot owns the
# Wi-Fi Direct adapter and runs its OWN NAT+DHCP (gateway 192.168.137.1).
#
# The failure mode: the tethering RADIO reports TetheringOperationalState='On'
# (clients associate, get a 192.168.137.x lease) while the NAT has no working
# PUBLIC side - so clients have NO internet. hotspot-start-core.ps1 used to
# early-return the instant the radio was 'On', so it was BLIND to this for hours.
#
# Why the public side dies: Mobile Hotspot records the upstream it NATs to in
# HKLM\...\icssvc\Settings\PublicConnectionSettings (a packed adapter ref). The
# USB LTE modem (Remote NDIS, "Ethernet 5") re-enumerates with a NEW identity on
# churn (modem reconnect, driver reload, sleep). The recorded public side then
# points at a dead adapter -> radio stays up, NAT egress is gone.
#
# Additional failure mode (2026-06-26): when upstream is Wi-Fi STATION (single
# radio shared with the Wi-Fi Direct AP), ICS internal NAT periodically loses
# its public-side binding even though the radio is up. This produced 333 visible
# stop-restart cycles in ~2 weeks - the user-visible "wifi keeps stopping then
# starting" complaint. Triggers were single-packet LTE drops on the detector.
#
# DO NOT try to fix this with ICS HNetShare EnableSharing(): Mobile Hotspot
# already owns the adapter, so EnableSharing throws 0x80040201
# ("event was unable to invoke any of the subscribers"). That is a SYMPTOM of
# the two NAT stacks colliding, not the cure. (Confirmed the hard way.)
#
# CORRECT CURE (aggressive, by design): stop tethering, re-read the CURRENT
# internet connection profile, start tethering -> it re-binds the live upstream
# as the public side and rebuilds its NAT.
#
# 2026-06-26 hardening to stop the stop-restart cycle:
#   1. Test-HotspotNat: multi-probe (3 targets, 2 pings each, 2.5s timeout) -
#      requires ALL probes to fail before declaring NAT dead. Single transient
#      packet loss no longer triggers a full tether rebuild.
#   2. Repair-HotspotNat: 90s cool-down between attempts (state file). Stops
#      back-to-back rebuilds when the underlying upstream needs a moment.
#   3. Repair-HotspotNat: try a gentle SharedAccess restart FIRST (clients keep
#      their 137.x lease, just ~5s of packet loss). Only fall through to full
#      Stop+Start tether if the service restart doesn't restore NAT.
#   4. Repair-HotspotNat: if 192.168.137.1 isn't bound after rebuild, force it
#      with New-NetIPAddress. Mobile Hotspot occasionally fails to bind.
#
# Dot-source alongside network-tuning.ps1. Every function is self-contained and
# idempotent. Requires the session to run with -ExecutionPolicy Bypass (the
# scheduled task already does).

Set-StrictMode -Off

$script:HotspotGatewayIp = '192.168.137.1'
$script:HotspotPrefixLength = 24
$script:RepairCooldownFile = 'C:\hotspot-last-repair.txt'
$script:RepairCooldownSeconds = 90
$script:NatFailCountFile = 'C:\hotspot-nat-fail-count.txt'

function Get-HotspotAdapter {
    Get-NetAdapter |
        Where-Object { $_.InterfaceDescription -like 'Microsoft Wi-Fi Direct Virtual Adapter*' -and $_.Status -eq 'Up' } |
        Select-Object -First 1
}

function Get-TetheringManager {
    # Bind to the CURRENT internet connection profile each call (this is the
    # public side Mobile Hotspot NATs to). Returns $null if there is no internet
    # profile at all (e.g. modem fully down).
    Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
    [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime] | Out-Null
    $conn = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if (-not $conn) { return $null }
    return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($conn)
}

function Test-HotspotNat {
    # True ONLY when the whole NAT path is genuinely usable:
    #   1. an internet-providing profile exists (the public side), AND
    #   2. the box itself can reach the internet through it, AND
    #   3. tethering radio is On, AND
    #   4. the hotspot adapter is Up and owns 192.168.137.1 (the private side).
    # Note: client internet == box-internet (#2) + working radio/private (#3,#4),
    # because Mobile Hotspot NATs the box's own egress. No ICS flags involved.
    param([scriptblock]$Log = { param($m) })

    $hotspot = Get-HotspotAdapter
    if (-not $hotspot) { & $Log 'NAT check: hotspot adapter not Up.'; return $false }

    $hasGwIp = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $hotspot.Name -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -eq $script:HotspotGatewayIp }
    if (-not $hasGwIp) { & $Log ("NAT check: hotspot missing " + $script:HotspotGatewayIp + '.'); return $false }

    $tm = Get-TetheringManager
    if (-not $tm) { & $Log 'NAT check: no internet connection profile (upstream down).'; return $false }
    if ($tm.TetheringOperationalState -ne 'On') { & $Log ('NAT check: tethering state=' + $tm.TetheringOperationalState + '.'); return $false }

    # THE client-path probe (load-bearing): ping the internet sourced from the
    # hotspot gateway IP (192.168.137.1). This packet originates on the PRIVATE
    # NAT scope, so it traverses the EXACT translation a real client uses. When
    # the Mobile-Hotspot public binding is stale (modem re-enumerated), this
    # FAILS even though a default-source ping from the box still succeeds (the
    # box egresses directly, bypassing NAT). A box-egress check is a FALSE
    # POSITIVE here - confirmed with a live client 2026-06-22. Do not "simplify"
    # this back to a plain Test-NetConnection.
    #
    # 2026-06-26: probe MULTIPLE targets with MULTIPLE pings each. NAT is alive
    # if ANY single probe gets a reply. This tolerates the transient LTE / Wi-Fi
    # packet drops that were triggering 333 false-positive repair cycles.
    $targets = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
    $probeOk = $false
    $probeDetail = @()
    foreach ($target in $targets) {
        $r = ping.exe -n 2 -w 2500 -S $script:HotspotGatewayIp $target 2>&1 | Out-String
        if ($r -match 'TTL=') { $probeOk = $true; $probeDetail += "$target=OK"; break }
        else { $probeDetail += "$target=FAIL" }
    }
    if (-not $probeOk) {
        & $Log ('NAT check: client-path NAT DEAD (all probes failed: ' + ($probeDetail -join ',') + ').')
        return $false
    }

    return $true
}

function Test-HotspotNatWithHysteresis {
    # Wraps Test-HotspotNat with 2-consecutive-fail hysteresis. Returns:
    #   $true  -> NAT is up, OR was down for just one tick (not yet confirmed)
    #   $false -> NAT confirmed down (>=2 consecutive fails) -> caller should Repair.
    # State persisted in $script:NatFailCountFile so it survives between task ticks.
    param([scriptblock]$Log = { param($m) })

    if (Test-HotspotNat -Log $Log) {
        # Clear failure counter on success.
        Remove-Item $script:NatFailCountFile -ErrorAction SilentlyContinue
        return $true
    }

    # Failure: read previous count, bump.
    $prevCount = 0
    if (Test-Path $script:NatFailCountFile) {
        try { $prevCount = [int](Get-Content $script:NatFailCountFile -ErrorAction SilentlyContinue) } catch { $prevCount = 0 }
    }
    $newCount = $prevCount + 1
    Set-Content -Path $script:NatFailCountFile -Value $newCount -Force -ErrorAction SilentlyContinue

    if ($newCount -lt 2) {
        & $Log ('NAT check: transient fail (' + $newCount + '/2) - not yet triggering Repair.')
        return $true  # Tell caller all good for now; wait for confirmation.
    }
    & $Log ('NAT check: ' + $newCount + ' consecutive fails - NAT confirmed DEAD.')
    return $false
}

function Test-RepairCooldown {
    # Returns $true if we are within the cool-down window since the last repair
    # attempt (caller should SKIP rebuilding). Caller is expected to call
    # Set-RepairCooldown after each rebuild attempt.
    param([scriptblock]$Log = { param($m) })

    if (-not (Test-Path $script:RepairCooldownFile)) { return $false }
    try {
        $last = [DateTime]::Parse((Get-Content $script:RepairCooldownFile -ErrorAction SilentlyContinue))
        $elapsed = (Get-Date) - $last
        if ($elapsed.TotalSeconds -lt $script:RepairCooldownSeconds) {
            & $Log ('Repair cool-down active (' + [int]$elapsed.TotalSeconds + 's of ' + $script:RepairCooldownSeconds + 's) - skipping.')
            return $true
        }
    } catch {}
    return $false
}

function Set-RepairCooldown {
    Set-Content -Path $script:RepairCooldownFile -Value ((Get-Date).ToString('o')) -Force -ErrorAction SilentlyContinue
}

function Restart-IcsServices {
    # Gentle NAT-rebuild path: restart SharedAccess (the ICS NAT engine). Clients
    # keep their 137.x DHCP lease and the Wi-Fi Direct radio stays up - they see
    # ~5s of packet loss vs ~60s when the full tether is cycled. Tries this
    # FIRST in Repair-HotspotNat before falling through to Stop+Start tether.
    param([scriptblock]$Log = { param($m) })
    try {
        & $Log '  gentle path: restarting SharedAccess (ICS NAT)...'
        Restart-Service SharedAccess -Force -ErrorAction Stop
        Start-Sleep -Seconds 4
        return $true
    } catch {
        & $Log ('  SharedAccess restart warn: ' + $_.Exception.Message)
        return $false
    }
}

function Set-HotspotGatewayIp {
    # Force-bind 192.168.137.1 on the hotspot adapter when Mobile Hotspot fails
    # to do it itself (intermittent on this hardware). Idempotent.
    param([scriptblock]$Log = { param($m) })
    $hotspot = Get-HotspotAdapter
    if (-not $hotspot) { return $false }
    $has = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $hotspot.Name -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -eq $script:HotspotGatewayIp }
    if ($has) { return $true }
    try {
        & $Log ('  binding ' + $script:HotspotGatewayIp + ' on ' + $hotspot.Name + ' (Mobile Hotspot failed to)')
        New-NetIPAddress -InterfaceAlias $hotspot.Name -IPAddress $script:HotspotGatewayIp -PrefixLength $script:HotspotPrefixLength -ErrorAction Stop | Out-Null
        return $true
    } catch {
        & $Log ('  manual IP bind warn: ' + $_.Exception.Message)
        return $false
    }
}

function Repair-HotspotNat {
    # Aggressive Mobile-Hotspot rebuild: hard Off->On cycle so tethering re-binds
    # the CURRENT upstream as its public side and rebuilds NAT+DHCP. Retries with
    # adapter recreation if the radio won't come back.
    #   StartHotspot: closure that runs the canonical starter to (re)create the
    #                 adapter + bring the radio On (e.g. hotspot-start-core.ps1).
    #
    # 2026-06-26: cool-down to prevent thrash; tries gentle SharedAccess restart
    # FIRST (less disruptive); manual IP bind fallback if Mobile Hotspot fails
    # to assign 192.168.137.1 after restart.
    param(
        [scriptblock]$Log = { param($m) },
        [scriptblock]$StartHotspot = $null
    )

    # Cool-down: bail early if we just tried a rebuild.
    if (Test-RepairCooldown -Log $Log) { return $false }
    Set-RepairCooldown

    & $Log '=== Repair-HotspotNat: Mobile-Hotspot rebuild START ==='

    # 0) Gentle path FIRST: restart SharedAccess. Often re-binds NAT without
    #    dropping the radio (clients keep their lease, ~5s packet loss).
    if (Restart-IcsServices -Log $Log) {
        Start-Sleep -Seconds 4
        Set-HotspotGatewayIp -Log $Log | Out-Null
        Start-Sleep -Seconds 2
        if (Test-HotspotNat -Log $Log) {
            & $Log '=== Repair-HotspotNat: gentle path SUCCESS (no radio cycle) ==='
            Remove-Item $script:NatFailCountFile -ErrorAction SilentlyContinue
            return $true
        }
        & $Log '  gentle path did not restore NAT, falling through to full tether cycle.'
    }

    # 1) Wait for a live internet profile first - no point cycling tethering with
    #    no public side to bind. Give the modem up to ~30s to re-present itself.
    $tm = $null
    for ($w = 0; $w -lt 10; $w++) {
        $tm = Get-TetheringManager
        if ($tm) { break }
        & $Log '  waiting for upstream internet profile...'
        Start-Sleep -Seconds 3
    }
    if (-not $tm) {
        & $Log '  ABORT: no upstream internet profile after wait (modem down). Will retry next tick.'
        return $false
    }

    # 2) Hard stop tethering (clears the stale public-side binding).
    try {
        if ($tm.TetheringOperationalState -eq 'On') {
            & $Log '  stopping tethering...'
            $tm.StopTetheringAsync() | Out-Null
            for ($k = 0; $k -lt 10 -and $tm.TetheringOperationalState -ne 'Off'; $k++) { Start-Sleep -Seconds 1 }
        }
    } catch { & $Log ('  stop warn: ' + $_.Exception.Message) }

    Start-Sleep -Seconds 2

    # 3) Re-acquire the CURRENT profile and start tethering -> re-binds live upstream.
    $on = $false
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $tm = Get-TetheringManager
        if (-not $tm) { & $Log ('  attempt ' + $attempt + ': upstream vanished, waiting...'); Start-Sleep -Seconds 3; continue }
        if ($tm.TetheringOperationalState -eq 'On') { $on = $true; break }
        & $Log ('  attempt ' + $attempt + ': StartTetheringAsync (binds ' + $tm.NetworkOperatorTetheringAccessPointConfiguration.Ssid + ')')
        try { $tm.StartTetheringAsync() | Out-Null } catch { & $Log ('  start warn: ' + $_.Exception.Message) }
        for ($k = 0; $k -lt 10; $k++) {
            Start-Sleep -Seconds 2
            if ($tm.TetheringOperationalState -eq 'On') { $on = $true; break }
        }
        if ($on) { break }
        # Radio stuck - let the canonical starter recreate the adapter and retry.
        if ($StartHotspot) { & $Log '  radio stuck, invoking StartHotspot to recreate adapter...'; try { & $StartHotspot } catch {} ; Start-Sleep -Seconds 3 }
    }

    if (-not $on) {
        & $Log '  rebuild FAILED: radio did not return On.'
        return $false
    }

    # 4) Force-bind the gateway IP if Mobile Hotspot didn't.
    Set-HotspotGatewayIp -Log $Log | Out-Null

    # 5) Re-clamp TCP on the (possibly recreated) hotspot adapter.
    if (Get-Command Set-HotspotTcpTuning -ErrorAction SilentlyContinue) {
        try { Set-HotspotTcpTuning -Log $Log } catch { & $Log ('  TCP re-clamp warn: ' + $_.Exception.Message) }
    }

    # 6) Verify with retries - the adapter / NAT can take >10s to fully settle
    #    after a full rebuild. Old code used a single Test-HotspotNat at +3s and
    #    falsely logged "STILL DOWN" while the next tick saw it verified.
    $ok = $false
    for ($v = 0; $v -lt 6; $v++) {
        Start-Sleep -Seconds 5
        if (Test-HotspotNat -Log $Log) { $ok = $true; break }
    }
    if ($ok) {
        & $Log '=== Repair-HotspotNat: rebuild END -> NAT RESTORED ==='
        Remove-Item $script:NatFailCountFile -ErrorAction SilentlyContinue
    } else {
        & $Log '=== Repair-HotspotNat: rebuild END -> NAT STILL DOWN ==='
    }
    return $ok
}
