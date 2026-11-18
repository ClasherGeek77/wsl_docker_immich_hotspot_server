# wsl_docker_immich_hotspot_server

## what it is

scripts and configuration that turn one Windows laptop into two things at once: a self-hosted photo server and a portable Wi-Fi router.

- WSL2 runs Docker, and Docker runs https://immich.app (photos), plus Postgres, Redis (Valkey), the machine-learning container and https://zrok.io (a public HTTPS tunnel to Immich).
- the laptop is reachable over https://tailscale.com .
- a USB LTE modem is the internet uplink, and the laptop shares it as a Wi-Fi hotspot.
- boot-reliability and TCP-stability fixes let it come back after a reboot with nobody logged in to fix it.

the reference setup is a used Fujitsu Lifebook U938 plus a USB LTE modem, about 189 USD in total (bill of materials and the reasoning for the TCP tuning are in `docs/hardware.md`).

the main problem it solves: WSL stops its VM when no Linux session is attached, which stops `dockerd`, and zrok then answers 502. the fix is a keepalive anchor, a foreground `wsl ... sleep` loop held open by a scheduled task. the full detail is in `docs/journal/`.

```
 Phone (Immich app, other apps)
    |  Wi-Fi
    v
 +-------------------- Windows laptop ------------------------------+
 |  Wi-Fi Direct hotspot  -->  Windows Mobile Hotspot (NAT)         |
 |                                   |                              |
 |  WSL2 (Ubuntu-22.04)              | USB                          |
 |   +- Docker: Immich, Postgres, Redis, ML, zrok                   |
 |        |                          v                              |
 |        |                  USB 4G LTE modem (Remote NDIS)         |
 |   Tailscale (mesh)                |  LTE                         |
 +--------|--------------------------|------------------------------+
          v                          v
   private mesh access        Internet --> zrok public HTTPS tunnel
```

## when to use it

- you want a home photo server on a spare Windows laptop that survives reboots without attention.
- you want to read a worked example of Windows scheduled tasks, WSL keepalive, and TCP tuning for a cheap USB modem.

when not to use it:

- you have a Linux machine or a NAS: install Immich with its own compose file, you do not need the WSL and hotspot parts.
- you are on macOS: the scripts are Windows PowerShell and WSL only.
- you want test automation: use https://github.com/ClasherGeek77/pytest_web_boilerplate

## what you need

- Windows 10 or 11 with an administrator account and PowerShell. the reference machine runs Windows 10 IoT LTSC (build 19044).
- WSL2 with the distro `Ubuntu-22.04`, and Docker installed inside it with `systemctl enable docker`. the installer checks for both.
- Tailscale installed and joined to your tailnet, from https://tailscale.com/download .
- a USB LTE modem that shows up as a Remote NDIS adapter, plugged in.
- a zrok account and enable token, from https://zrok.io .
- a data disk for the photos (the example paths use `D:`, `/mnt/d/home-server/photos`).
- RAM: the sample `windows/wslconfig-template` caps WSL at 4500 MB plus 4 GB swap, written for a host with 7.8 GB RAM. adjust `memory` for your machine.

## quick start

from an elevated PowerShell, at the root of the repository:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

the installer is interactive and safe to re-run. it does these steps in order:

1. checks that you are an administrator, that the WSL distro exists, and whether Docker is active in WSL.
2. copies the scripts to `C:\home-server\` (`runtime\`, `setup\`, `lib\`, plus `logs\` and `state\`).
3. creates `immich\.env` from `immich\.env.example` if it does not exist, and asks for `DB_PASSWORD`, `ZROK_ENABLE_TOKEN`, `ZROK_SHARE_NAME`, `HOTSPOT_SSID` and `HOTSPOT_PASSPHRASE`. an existing `.env` is never overwritten.
4. copies `windows\wslconfig-template` to `%USERPROFILE%\.wslconfig` if you have none, and runs `setup\wsl-harden.ps1` (pins WSL and container DNS).
5. registers the scheduled tasks `AutoStartWSL`, `WSLDockerHealth` and `AutoHotspotHealth`.
6. turns on TCP BBR in WSL and runs `docker compose up -d` for the Immich stack.
7. starts the hotspot, applies the TCP tuning, and prints a health summary.

options: `-InstallRoot` (default `C:\home-server`), `-Distro` (default `Ubuntu-22.04`), `-SkipDocker`, `-SkipHotspot`.

you should see numbered steps with `OK` lines and, at the end, the scheduled tasks listed with their state, `Docker in WSL : active`, and the `netsh` TCP settings. then Immich answers on port 2283 of the laptop. not run here (it needs Windows, WSL, a USB modem and real secrets). what was checked: `install.ps1`, the compose file and the task scripts were read.

## manual operation

if you skip the installer:

```powershell
# 1. secrets
cp immich\.env.example immich\.env   # then edit with real values

# 2. copy the scripts to C:\home-server\{runtime,setup,lib}

# 3. register the tasks, pointing them at the copied runtime folder
windows\setup\register-tasks.ps1 -RuntimeDir C:\home-server\runtime

# 4. Immich and zrok
wsl -d Ubuntu-22.04 -u root -- bash -c "cd /mnt/d/home-server/immich && docker compose up -d"

# 5. hotspot and TCP tuning
C:\home-server\runtime\hotspot-start.ps1
C:\home-server\setup\tcp-tune.ps1
```

## health check

```powershell
Get-ScheduledTask | ? { $_.TaskName -match 'WSL|Hotspot|Docker' } | ft TaskName,State
wsl -d Ubuntu-22.04 -u root -- systemctl is-active docker
curl -I https://<your-share>.share.zrok.io      # expect HTTP 200
netsh int tcp show global | findstr /i "auto-tuning ecn"
```

## how to read the code

```
install.ps1                  one-click installer (copies to C:\home-server\)
immich/
  docker-compose.yml         Immich, Postgres, Redis (Valkey), ML, zrok (5 services)
  .env.example               copy to .env and fill the secrets (.env is gitignored)
windows/                     Windows side, split by role
  runtime/                   scripts the system runs by itself
    keepalive-anchor.ps1       holds the WSL VM open (task AutoStartWSL)
    health-watchdog.ps1        5-minute self-heal (task WSLDockerHealth)
    hotspot-start.ps1          hotspot start, verify and retry
    hotspot-start-core.ps1     the core used by hotspot-start.ps1
  setup/                     scripts run once at install time
    register-tasks.ps1         (re)register the scheduled tasks
    tcp-tune.ps1               global and per-adapter TCP/QoS tuning
    wsl-harden.ps1             pin WSL and container DNS (keeps zrok reachable)
    sync-to-repo.ps1           copy the running scripts back into the repo, commit, push
  lib/
    network-tuning.ps1         shared ClampMss, vboxnetflt and global TCP helpers
    immich-guard.ps1           health probes and targeted repairs for the stack
    hotspot-nat-guard.ps1      end-to-end hotspot NAT check and self-heal
  wslconfig-template         .wslconfig with the WSL memory cap
  README.md                  per-script deep dive
docs/
  hardware.md                bill of materials, why a cheap modem needs TCP tuning
  immich-map.md              where each part of the stack lives
  plan-winnat.md             plan to move WSL off ICS (partly done)
  journal/                   dated incident log, history and not spec
```

the split to understand is `runtime/` versus `setup/`: Windows runs `runtime/` scripts on a schedule or forever, and you (or `install.ps1`) run `setup/` scripts once. `runtime/` and `setup/` must stay next to `lib/`, because they load `..\lib\network-tuning.ps1` relative to their own location.

read in this order: `install.ps1`, `windows/README.md`, `windows/runtime/keepalive-anchor.ps1`, `immich/docker-compose.yml`, `docs/hardware.md`, then `docs/journal/`.

## if it breaks

| symptom | cause | fix |
| --- | --- | --- |
| the zrok URL answers 502 while Immich works on `localhost:2283` | the WSL VM stopped (no keepalive), or DNS inside WSL or the containers broke | check the `AutoStartWSL` task is Running; run `windows\setup\wsl-harden.ps1`; see `docs/journal/` |
| `install.ps1` stops with "Must run as Administrator" | PowerShell is not elevated | open PowerShell as administrator |
| `install.ps1` stops with "WSL distro ... not found" | the distro name differs | `wsl --install -d Ubuntu-22.04`, or pass `-Distro <name>` |
| the hotspot is On but phones have no internet | the hotspot NAT lost its public side after the modem re-plugged | wait for the `AutoHotspotHealth` task, or run `windows\runtime\hotspot-start.ps1` |
| calls and streams stall on the hotspot | cheap-modem packet fragmentation and window growth | run `windows\setup\tcp-tune.ps1`; the reasons are in `docs/hardware.md` |
| `immich_server` is killed for memory | WSL has too much or too little memory | edit `memory` in `%USERPROFILE%\.wslconfig`, then `wsl --shutdown` |
| the image version is not what `.env` says | `docker-compose.yml` pins `v3.1.0` for Immich and ignores `IMMICH_VERSION` from `.env.example` (`v2`) | edit the tags in `docker-compose.yml` |
| the repo gets a commit and a push you did not expect | `windows\setup\sync-to-repo.ps1` commits and pushes | do not schedule or run it unless you want that |

## secrets

nothing secret is committed. real values live in `immich/.env` (gitignored); the template is `immich/.env.example`. the hotspot passphrase and zrok token are read from that file and must not be hard-coded. the zrok identity folders (`.zrok/`, `.zrok2/`) are gitignored too. note that `docs/immich-map.md` and `docs/journal/` contain real host details from the author's setup (host name, addresses, a share name): remove them before you reuse or share this repository.

## next

- the hardware and TCP reasoning: `docs/hardware.md` in this repository.
- an Android UI inspection tool in Docker: https://github.com/ClasherGeek77/uiautomatorviewer_docker_novnc
- Linux workstation setup scripts: https://github.com/ClasherGeek77/linux_qa_environment_setup_script
- all repositories: https://github.com/ClasherGeek77
