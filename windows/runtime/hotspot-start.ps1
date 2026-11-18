# hotspot-start.ps1  (LOOP WRAPPER added 2026-06-12)
# Windows Task Scheduler enforces a 1-minute MINIMUM repetition interval, so a
# true 15s task trigger is impossible. Instead AutoHotspotHealth fires this
# wrapper once a minute and we run the real health check (hotspot-start-core.ps1)
# 4 times, 15s apart -> effective 15s cadence. Overlap is prevented by the
# task's MultipleInstancesPolicy=IgnoreNew and the PT4M ExecutionTimeLimit.
$core = Join-Path $PSScriptRoot 'hotspot-start-core.ps1'
for ($i = 0; $i -lt 4; $i++) {
    try { & $core } catch {}
    if ($i -lt 3) { Start-Sleep -Seconds 15 }
}
