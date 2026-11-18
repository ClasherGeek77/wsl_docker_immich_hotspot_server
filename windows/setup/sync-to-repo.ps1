# sync-to-repo.ps1 - mirror the LIVE runtime back into the git repo, commit, push.
#
# WHY: C:\home-server\ is the runtime and is NOT a git repo. Fixes get made there
# under pressure during an outage and then quietly diverge from the repo, which is
# exactly what happened before (the wrapper/core split was fixed on-box on 2026-06-12
# and only back-ported months later). If the laptop is ever reinstalled, anything that
# lives only in C:\home-server\ is lost. Running this on a loop keeps the repo an
# accurate, one-click-restorable snapshot of what is actually running.
#
# Safe to run every few minutes: it is a no-op when nothing changed, and it never
# force-pushes or rewrites history.

[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\home-server',
    [string]$RepoRoot    = 'C:\github\home-server-repro',
    [string]$ImmichDir   = 'D:\home-server\immich',
    [switch]$NoPush
)

$ErrorActionPreference = 'Continue'
$log = Join-Path $InstallRoot 'state\sync-to-repo.log'
function Log($m) {
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $m
    try { $line | Out-File -FilePath $log -Append -Encoding utf8 } catch { }
    Write-Output $line
}

if (-not (Test-Path $RepoRoot)) { Log "repo not found at $RepoRoot"; exit 1 }

# Copy only real scripts. *.bak-* files are on-box safety copies and must never
# reach the repo - they would bloat it and make the history meaningless.
$pairs = @(
    @{ From = (Join-Path $InstallRoot 'lib');     To = (Join-Path $RepoRoot 'windows\lib') },
    @{ From = (Join-Path $InstallRoot 'runtime'); To = (Join-Path $RepoRoot 'windows\runtime') },
    @{ From = (Join-Path $InstallRoot 'setup');   To = (Join-Path $RepoRoot 'windows\setup') }
)

$copied = 0
foreach ($p in $pairs) {
    if (-not (Test-Path $p.From)) { continue }
    New-Item -ItemType Directory -Path $p.To -Force | Out-Null
    Get-ChildItem $p.From -File -Filter '*.ps1' |
        Where-Object { $_.Name -notmatch '\.bak' } |
        ForEach-Object {
            $dest = Join-Path $p.To $_.Name
            $differs = $true
            if (Test-Path $dest) {
                $differs = (Get-FileHash $_.FullName).Hash -ne (Get-FileHash $dest).Hash
            }
            if ($differs) { Copy-Item $_.FullName $dest -Force; $copied++ }
        }
}

# The Immich compose file is the OTHER half of a restore. It pins the exact image
# tags actually running (e.g. the v2.6.3 -> v3.1.0 upgrade on 2026-08-29), so if it
# is not mirrored the repo would happily reinstall a stale version.
# .env is NEVER copied - it holds DB_PASSWORD and ZROK_ENABLE_TOKEN and is gitignored.
$composeSrc = Join-Path $ImmichDir 'docker-compose.yml'
$composeDst = Join-Path $RepoRoot 'immich\docker-compose.yml'
if (Test-Path $composeSrc) {
    $differs = $true
    if (Test-Path $composeDst) {
        $differs = (Get-FileHash $composeSrc).Hash -ne (Get-FileHash $composeDst).Hash
    }
    if ($differs) { Copy-Item $composeSrc $composeDst -Force; $copied++; Log 'immich/docker-compose.yml updated' }
}

Push-Location $RepoRoot
try {
    $dirty = & git status --porcelain 2>&1
    if (-not $dirty) {
        Log "no drift (copied=$copied) - nothing to commit"
        Pop-Location
        exit 0
    }

    $files = ($dirty | ForEach-Object { ($_ -replace '^\s*\S+\s+', '') }) -join ', '
    Log ("drift detected: " + $files)

    & git add -A 2>&1 | Out-Null

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $msg = @"
chore: sync live runtime from pc-remote ($stamp)

Mirrors C:\home-server\ back into the repo so a fresh OS install can be restored
with install.ps1. Committed automatically by sync-to-repo.ps1.

Files: $files
"@
    # WriteAllText with a BOM-less UTF8 encoder, NOT Set-Content -Encoding UTF8:
    # PowerShell 5.1 writes a BOM, and git takes it as part of the subject line, so
    # every commit ends up titled "﻿chore: ..." instead of "chore: ...".
    $tmp = Join-Path $env:TEMP 'home-server-sync-msg.txt'
    [System.IO.File]::WriteAllText($tmp, $msg, (New-Object System.Text.UTF8Encoding($false)))
    & git commit -F $tmp 2>&1 | Select-Object -Last 3 | ForEach-Object { Log ("  " + $_) }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue

    if ($NoPush) { Log 'commit done; push skipped (-NoPush)'; Pop-Location; exit 0 }

    $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new'
    $push = & git push origin main 2>&1
    if ($LASTEXITCODE -eq 0) {
        Log 'pushed to origin/main'
    } else {
        # Never force. If the remote moved, leave it for a human to reconcile.
        Log ('PUSH FAILED: ' + ($push | Select-Object -Last 2))
    }
} finally {
    Pop-Location
}
