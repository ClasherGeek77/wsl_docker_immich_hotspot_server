# 2026-08-29 — Immich/zrok unreachable for ~13 days: ICS churn destroys WSL networking

## Symptom

`https://<your-share>.share.zrok.io` returned **502** continuously from ~Aug 16 to Aug 29.

What made this hard: **from inside the box everything looked healthy.**

- `docker ps` → all 5 Immich containers `Up` (some for 2 months)
- `curl http://127.0.0.1:2283/api/server/ping` → `HTTP 200`
- dockerd active, WSL responding, scheduled tasks running

The old watchdog concluded "zrok is broken" and ran `docker restart immich_zrok`
**3737 consecutive times over ~13 days**, logging a failure each cycle and never
escalating or alerting.

## Root cause

```
hotspot tethering cannot reach On
  (upstream was Wi-Fi "FailoverZone"; the USB modem had been absent for weeks)
    -> AutoHotspotHealth fires StartTetheringAsync 5x/min, forever
      -> that ICS churn stops / wedges icssvc
        -> WSL2's network is an HNS network named "WSL" of Type=ICS, OWNED by icssvc
          -> the WSL VM comes back with NO usable NIC
             (no eth0 at all, or eth0 holding a stale address whose gateway is gone)
            -> containers lose all external network
              -> zrok cannot resolve api-v1.zrok.io, cannot build its Ziti session
                -> public share 502s
```

`icssvc` being **Stopped** is the tell. Immich keeps serving on localhost throughout,
which is why every inside-the-box health signal stayed green.

## What does NOT fix it

Verified by hand, in this order — all failed:

- `wsl --shutdown`, repeatedly
- `Restart-Service WslService` / `LxssManager`
- disable/enable the `vEthernet (WSL)` adapter
- `Remove-HnsNetwork` on its own (the network is simply never rebuilt)

## What does fix it

1. Stop the `AutoStartWSL` anchor **first**. It holds a foreground `wsl … sleep` loop
   whose job is to restart WSL instantly, so `wsl --shutdown` is undone within a
   second and the VM re-enters mid-rebuild, ending up with eth0 + a dead gateway that
   survives the rest of the repair.
2. `wsl --shutdown`, then remove the stale HNS `WSL` network.
3. `sc.exe` stop `SharedAccess` → stop `icssvc` → start `icssvc` → start `SharedAccess`,
   with 4–8 s settle between each. `Restart-Service -Force` reports "stop failed" here;
   `sc.exe` drives the same transition cleanly.
4. Boot WSL **once**, then hand back to the anchor.
5. Verify **egress**, not interface presence — see below.

Implemented as `Repair-WslNetwork` in `windows/lib/immich-guard.ps1`.

## Fixes shipped

| Fix | Where | Why |
|---|---|---|
| Hotspot failure cooldown (30 min after 2 failed runs) | `runtime/hotspot-start-core.ps1` | Stops the ICS churn at source. **Load-bearing — do not remove.** |
| Cooldown clears on upstream change / when already On | same | So restoring USB tethering or a LAN cable retries immediately instead of waiting out a cooldown earned by a different upstream |
| Await `StartTetheringAsync`; never re-issue during `InTransition` | same | The old loop discarded the result and cancelled its own in-flight attempts. Awaiting it named the real fault instantly: `WiFiDeviceOff` |
| Self-heal `WiFiDeviceOff` by restarting the Wi-Fi adapter | same | The radio reported "Software On" and `Radio.State=On` while seeing 0 networks. `Restart-NetAdapter Wi-Fi` cured it; tethering then returned `Success` first try |
| Single-instance mutex | `hotspot-start-core.ps1`, `health-watchdog.ps1` | Overlapping runs cancelled each other — two `Repair-WslNetwork` calls each tore down the VM the other was waiting for |
| 9 layered probes + escalation ladder + backoff | `runtime/health-watchdog.ps1` | Replaces one blind repair applied to every failure |
| `L2b_wslnet` egress probe | `lib/immich-guard.ps1` | Interface presence is not connectivity — see below |
| `Ensure-IcsService` every cycle | `lib/immich-guard.ps1` | Preventive: restart `icssvc` before it can take WSL down |
| `Ensure-UpstreamMetrics` | `lib/immich-guard.ps1` | Stable upstream choice = less ICS re-binding. Only prefers a wired link that **actually has internet** |
| DNS pinned (immutable resolv.conf + `daemon.json` dns) | `setup/wsl-harden.ps1` | WSL rewrites resolv.conf to a dead proxy within seconds |
| Tasks use `S4U`, not `Interactive` | `setup/register-tasks.ps1` | Interactive tasks never fire on a headless box |
| Health task limit 4 min → 10 min | `setup/register-tasks.ps1` | A 4-minute cap killed `Repair-WslNetwork` midway |

## Traps worth remembering

- **Interface presence ≠ connectivity.** After an HNS rebuild the guest keeps its old
  address and gateway while the host-side `vEthernet (WSL)` has no IPv4 at all. eth0 is
  up, has a default route, and routes nowhere. Probe egress by IP
  (`curl https://1.1.1.1/`), never by name — that would blur into the DNS layer.
- **Never set a low interface metric on a wired link that is up but dead.** It
  blackholes traffic and takes the box off the network entirely. Check
  `IPv4Connectivity -eq 'Internet'` first.
- **`docker compose` was broken on this box the whole time.** The plugin negotiates
  Docker API v1.53, dockerd caps at v1.41, and the `docker-compose` v1.25 fallback is
  too old to parse the file (`mem_limit`). Every compose-based repair would have failed
  during a real outage. Fixed by exporting `DOCKER_API_VERSION` read from
  `docker version --format '{{.Server.APIVersion}}'`.
- **Always `--no-deps` on `--force-recreate zrok`**, or it cascades through
  `depends_on` and bounces Postgres to fix a tunnel.
- **Do not reboot casually.** Recovery depends on `AutoStartWSL` firing at boot; the
  watchdog will only reboot if `C:\home-server\state\ALLOW_REBOOT` exists.

## Verification

Each repair was proven by fault injection, not by reasoning:

- DNS poisoned → detected `L4_wsldns`, repaired, resolving again
- Core container stopped → detected `L8_roster`, restarted
- zrok detached from its network → healed at tier 2, Postgres confirmed untouched
- Backoff armed while broken → repair suppressed, container provably not touched
- WSL network destroyed → `Repair-WslNetwork` restored eth0 + egress; later the
  scheduled watchdog healed the same fault unattended (`HEALED at tier 1 (L2b_wslnet)`)

End state: 9/9 layers green, `zrok=200` verified from an external host.
