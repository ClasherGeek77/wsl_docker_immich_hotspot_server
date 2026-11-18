param(
  [string]$RuntimeDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime'),
  [string]$HostUser   = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
)
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'

# Tasks point at the staged runtime dir (default: sibling 'runtime' of this setup
# folder). install.ps1 passes C:\home-server\runtime explicitly.
$WslUp     = Join-Path $RuntimeDir 'keepalive-anchor.ps1'
$WslHealth = Join-Path $RuntimeDir 'health-watchdog.ps1'

Write-Output '=== Removing dead/superseded tasks ==='
foreach ($t in 'AutoStartWSLBoot','AutoHotspot') {
  if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $t -Confirm:$false
    Write-Output ('Deleted: ' + $t)
  } else { Write-Output ('Not present: ' + $t) }
}

Write-Output '=== Rebuilding AutoStartWSL (keepalive anchor) ==='
# Remove old one first
if (Get-ScheduledTask -TaskName 'AutoStartWSL' -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName 'AutoStartWSL' -Confirm:$false
  Write-Output 'Removed old AutoStartWSL'
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WslUp`""

# Two triggers: at ted's logon (autologon fires this) AND at startup (redundancy).
$trigLogon = New-ScheduledTaskTrigger -AtLogOn -User $HostUser
$trigBoot  = New-ScheduledTaskTrigger -AtStartup

# Run as the host user with S4U ("run whether logged on or not"), highest privileges.
#
# NOT Interactive: this box is headless, and an Interactive task only fires when a
# real interactive session exists. On a stale/disconnected session it silently never
# runs, so WSL never starts and the server is dead until someone logs in physically.
# NOT SYSTEM either: WSL hard-blocks the local SYSTEM account
# (WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED).
# S4U runs as the user without storing a password - verified working 2026-08-29.
$principal = New-ScheduledTaskPrincipal -UserId $HostUser -LogonType S4U -RunLevel Highest

# Settings: keepalive runs forever; restart if it dies; no time limit; start when available.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
$settings.MultipleInstances = 'IgnoreNew'  # don't stack anchors
$settings.DisallowStartOnRemoteAppSession = $false

Register-ScheduledTask -TaskName 'AutoStartWSL' -Action $action -Trigger @($trigLogon,$trigBoot) -Principal $principal -Settings $settings -Description 'Boots WSL, ensures Docker, and stays alive as the WSL keepalive anchor (fixes zrok 502 from WSL idle-out).' | Out-Null
Write-Output 'Registered AutoStartWSL'

Write-Output '=== Creating WSLDockerHealth (every 5 min self-heal) ==='
if (Get-ScheduledTask -TaskName 'WSLDockerHealth' -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName 'WSLDockerHealth' -Confirm:$false
}
$haction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WslHealth`""
$htrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::FromDays(9999))
$hprincipal = New-ScheduledTaskPrincipal -UserId $HostUser -LogonType S4U -RunLevel Highest
# 10 min, not 4: Repair-WslNetwork tears the VM down, bounces ICS and waits for the
# network to return, which can take several minutes. A 4-minute cap killed the repair
# midway and left the box network-less.
$hsettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$hsettings.MultipleInstances = 'IgnoreNew'
Register-ScheduledTask -TaskName 'WSLDockerHealth' -Action $haction -Trigger $htrigger -Principal $hprincipal -Settings $hsettings -Description 'Every 5 min: ensure WSL keepalive task is running and Docker is up. Self-heal layer.' | Out-Null
Write-Output 'Registered WSLDockerHealth'

Write-Output '=== Creating AutoHotspotHealth (every 5 min hotspot self-heal) ==='
if (Get-ScheduledTask -TaskName 'AutoHotspotHealth' -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName 'AutoHotspotHealth' -Confirm:$false
}
$hotspotScript = Join-Path $RuntimeDir 'hotspot-start.ps1'
$hactionHotspot = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$hotspotScript`""
$htriggerHotspot = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::FromDays(9999))
$hprincipalHotspot = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
# 2026-08-31: no cap here meant a wedged run (radio stuck InTransition, WinRT
# call hung) could block every future 5-min tick silently forever - exactly
# what happened to WSLDockerHealth (LastTaskResult 267009, stuck 15+ min).
# hotspot-start.ps1's own retry loop tops out around 90-120s; 4 min gives
# headroom without letting a hang survive multiple ticks.
$hsettingsHotspot = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
$hsettingsHotspot.MultipleInstances = 'IgnoreNew'
Register-ScheduledTask -TaskName 'AutoHotspotHealth' -Action $hactionHotspot -Trigger $htriggerHotspot -Principal $hprincipalHotspot -Settings $hsettingsHotspot -Description 'Every 5 min: ensure hotspot is active and apply TCP tuning. Self-heal layer.' | Out-Null
Write-Output 'Registered AutoHotspotHealth'

Write-Output '=== Final task inventory ==='
Get-ScheduledTask | Where-Object {$_.TaskName -match 'WSL|Hotspot|Docker'} | Select-Object TaskName,State | Format-Table -AutoSize
