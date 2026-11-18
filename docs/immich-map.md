# pc-remote — Immich stack: full map

Snapshot taken 2026-08-29. Host `<hostname>`, Windows 10 IoT (build 19044),
Tailscale node `<hostname>` @ `<tailscale-ip>`.

This is the "where does everything actually live" document. For the *why* behind the
networking fixes, see [`2026-08-29-wsl-ics-outage.md`](./2026-08-29-wsl-ics-outage.md).

---

## 1. Physical / logical layers

Immich does not run on Windows. It runs in Docker, inside a WSL2 VM, on Windows.
Four layers, each with its own failure mode:

```
Windows 10 IoT (host, 7.8 GB RAM)
└── WSL2 VM  "Ubuntu-22.04"   (4.5 GB RAM + 4 GB swap, eth0 172.25.0.144/20)
    └── dockerd (systemd unit, live-restore=true)
        └── compose project "immich"  @ /mnt/d/home-server/immich
            ├── immich_server
            ├── immich_machine_learning
            ├── immich_postgres
            ├── immich_redis
            └── immich_zrok
```

---

## 2. The two access paths

Two completely separate routes reach the same container. They fail independently —
always establish *which* one is broken before diagnosing.

### A. LAN / phone (fast path, no tunnel)

```
phone 192.168.137.74
  → Wi-Fi Direct hotspot "ThienServer"  gateway 192.168.137.1  (LinkSpeed ~104 Mbps)
    → netsh portproxy  0.0.0.0:2283 → 172.25.0.144:2283
      → WSL eth0 → docker → immich_server:2283
```

⚠️ **The portproxy target `172.25.0.144` is hardcoded.** That is the WSL VM's IP, and
it can change on a WSL restart. When it does, `192.168.137.1:2283` breaks completely
(connection refused) until the rule is re-added:

```powershell
netsh interface portproxy show all
netsh interface portproxy add v4tov4 listenport=2283 listenaddress=0.0.0.0 `
      connectport=2283 connectaddress=<current WSL eth0 IP>
```

Also note every byte of an upload is relayed through this userspace proxy, so a WSL
restart mid-upload severs the connection (client sees a broken pipe).

### B. Public (zrok tunnel)

```
https://<your-share>.share.zrok.io
  → zrok public frontend (NetFoundry / OpenZiti)
    → immich_zrok container  → http://immich-server:2283
```

zrok runs headless with a reserved share:

```
zrok share reserved "<your-share>" --headless --insecure \
     --override-endpoint http://immich-server:2283
```

Health probe used everywhere: `https://<your-share>.share.zrok.io/api/server/ping` → `{"res":"pong"}`.
`502` = tunnel up, backend unreachable. `000` = zrok itself down.

---

## 3. Containers

| Container | Image | mem_limit | memswap | Restart |
|---|---|---|---|---|
| `immich_server` | `ghcr.io/immich-app/immich-server:v3.1.0` | **2560m** | 4096m | always |
| `immich_machine_learning` | `ghcr.io/immich-app/immich-machine-learning:v3.1.0` | **1536m** | 2560m | always |
| `immich_postgres` | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` (digest-pinned) | unlimited | — | always |
| `immich_redis` | `docker.io/valkey/valkey:9` (digest-pinned) | unlimited | — | always |
| `immich_zrok` | `openziti/zrok:1.1.10` | unlimited | — | always |

Only `immich_server` publishes a port: `0.0.0.0:2283->2283/tcp`.

**Unrelated containers on the same docker host** (separate stack, do not confuse them
with Immich): `umbrel` (:88), `auth` (:2000), `tor_proxy`.

### Memory limits are load-bearing

`mem_limit` on `immich_server` is not arbitrary. It exists so the **cgroup** OOM-killer
takes Immich rather than the host kernel OOM-killer taking the whole WSL VM (incident
2026-06-22). But sized too small it becomes the bug: at `1500m`, v3.1.0's server plus
the ffmpeg it spawns during upload exceeded the cap, the cgroup killed the process, and
large uploads died mid-write with a random broken pipe. Raised to `2560m` on 2026-08-29;
observed peak afterwards ~1191 MB, zero OOM events.

`memswap_limit` must stay **above** `mem_limit`. When they are equal, Docker disables
swap for that container entirely — which silently made the swap file useless.

---

## 4. Storage

| Path | Purpose |
|---|---|
| `/mnt/d/home-server/photos` | `UPLOAD_LOCATION` — bind-mounted into `immich_server` as **`/data`** |
| `/mnt/d/home-server/photos/library` | the actual photo/video library (**13 GB**) |
| `/mnt/d/home-server/photos/upload` | staging for in-flight uploads |
| `/mnt/d/home-server/photos/encoded-video` | transcoded video |
| `/mnt/d/home-server/photos/thumbs` | thumbnails |
| `/mnt/d/home-server/photos/backups` | Immich's automatic **DB-only** dumps, daily ~10:00 |
| `/mnt/d/home-server/photos/.db` | `DB_DATA_LOCATION` |
| docker volume `immich_pgdata` | Postgres data |
| docker volume `immich_model-cache` | ML models |

`/mnt/d` is a **9p/drvfs mount of the Windows D: drive**. Measured write throughput
194 MB/s — adequate; it has been ruled out as an upload bottleneck. D: has ~97 GB free
of 116 GB.

**Because `/mnt/d/home-server/photos` is already mounted as `/data`, an External Library
needs no compose change**: create `/mnt/d/home-server/photos/external` and register it
in Immich as `/data/external`.

### Backups — know the gap

The daily dumps cover the **database only** (~27 MB gzipped). The **13 GB of photos has
no backup.** An Immich upgrade never touches the library, but a disk failure would.

---

## 5. Database

- Postgres **14.19**, extensions: `vchord 0.4.3`, `vector 0.8.1`, plus `pg_trgm`, `cube`,
  `earthdistance`, `unaccent`, `uuid-ossp`, `plpgsql`
- Size **173 MB**; **1919 assets**, 173 people, 3 albums
- Vector indexes `clip_index` / `face_index` use `vchordrq`

Already on **VectorChord**, *not* pgvecto.rs — so the v3 removal of pgvecto.rs did not
apply here. `DB_VECTOR_EXTENSION` is deliberately unset; Immich auto-detects.

The postgres image is digest-pinned to **exactly** what Immich v3.1.0's own compose
ships, so server upgrades within v3 need no DB image change.

---

## 6. Configuration

`.env` (secrets — never committed; only `.env.example` is in git):

```
UPLOAD_LOCATION=/mnt/d/home-server/photos
DB_DATA_LOCATION=/mnt/d/home-server/photos/.db
DB_USERNAME=postgres  DB_DATABASE_NAME=immich  DB_HOSTNAME=database
DB_PASSWORD=***       ZROK_ENABLE_TOKEN=***    ZROK_SHARE_NAME=<your-share>
IMMICH_VERSION=v2     ← NOT USED: compose hardcodes image tags
```

⚠️ `IMMICH_VERSION` is a decoy. `docker-compose.yml` pins tags literally, so
`docker compose pull` alone will never upgrade Immich — you must edit the two `image:`
lines.

`%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
memory=4500MB
swap=4GB
swapFile=D:\wsl-swap.vhdx    ← D:, single backslash. See below.
```

Swap was silently **absent from 2026-06-26 to 2026-08-29** for two compounding reasons:
the value was `C:\\wsl-swap.vhdx` (escaped backslash = invalid path), *and* C: has only
0.2 GB free so the file could never be created anyway. With no swap, memory pressure went
straight to an OOM kill instead of swapping.

> **C: is at 0.2 GB free of 122 GB.** Unresolved, and a plausible contributor to this
> box's general instability — Windows needs headroom for pagefile, updates and temp.

### DNS — three independent pins

WSL regenerates `/etc/resolv.conf` to point at a Windows-side DNS proxy that dies whenever
the upstream changes. When that happens containers lose DNS, zrok cannot resolve
`api-v1.zrok.io`, and the public share 502s — while Immich still answers 200 on localhost.

1. `/etc/resolv.conf` → `1.1.1.1 / 8.8.8.8 / 9.9.9.9`, made **immutable** (`chattr +i`)
2. `/etc/wsl.conf` → `[network] generateResolvConf = false`
3. `/etc/docker/daemon.json` → `{"live-restore": true, "dns": [...]}` ← the one that
   actually keeps zrok alive, since it survives resolv.conf being clobbered

---

## 7. Scheduled tasks (Windows)

| Task | Runs | Purpose |
|---|---|---|
| `AutoStartWSL` | AtStartup + AtLogon, **S4U**, Highest | keepalive **anchor** — blocks in a foreground `wsl … sleep` loop to hold the VM open |
| `WSLDockerHealth` | every 5 min, S4U, limit 10 min | the health watchdog |
| `AutoHotspotHealth` | every 1 min, SYSTEM | hotspot start / NAT self-heal |
| `AutoHotspotBoot` | AtStartup | hotspot at boot |

**S4U, not Interactive.** Interactive tasks never fire on this headless box; SYSTEM is
hard-blocked by WSL (`WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED`). S4U runs as `ted` with no
stored password.

`LastTaskResult=267009` on the anchor is **normal** — it means `SCHED_S_TASK_RUNNING`.

If WSL is `Stopped` while the anchor says `Running`, the anchor's inner `wsl.exe` hold
has died; restarting the task re-establishes it.

---

## 8. Health watchdog

`C:\home-server\runtime\health-watchdog.ps1`, backed by `C:\home-server\lib\immich-guard.ps1`.
Probes 9 layers **in dependency order** and repairs only the lowest broken one.

| Layer | Meaning |
|---|---|
| `L1_anchor` | AutoStartWSL task running |
| `L2_wsl` | WSL responds |
| `L2b_wslnet` | eth0 + default route + **real egress** (probes `https://1.1.1.1/` by IP) |
| `L3_dockerd` | docker daemon active |
| `L4_wsldns` | WSL resolves public names |
| `L8_roster` | all 5 core containers Up |
| `L5_ctrdns` | container resolves via Docker DNS `127.0.0.11` |
| `L6_immich` | Immich answers on `localhost:2283` |
| `L7_zrokpub` | public share returns 200 |

`L2b` sits **above** dockerd deliberately: a NIC-less VM runs dockerd and every container
perfectly happily, so checking docker first reports healthy when the box is unreachable.
It tests egress rather than interface presence, because after an HNS rebuild eth0 stays
up with a default route that leads nowhere.

State: `C:\home-server\state\health-status.json` (machine-readable), `health-state.json`
(escalation state), `incidents.log`. Log: `C:\wsl-health.log` (auto-rotated at 5 MB).

Repairs escalate by tier while the *same* layer keeps failing, and back off once the
ladder is exhausted rather than looping forever. Both the watchdog and the hotspot script
hold a `Global\` mutex — overlapping runs used to cancel each other's work.

`health-status.json.layers` is the **pre-repair** snapshot. On a cycle that repaired
something, read `postRepairOk`, not `layers`.

---

## 9. Operational gotchas

- **Distro name is `Ubuntu-22.04`**, not `Ubuntu`. The wrong name *hangs* instead of erroring.
- **Compose needs the API version pinned** or every compose command fails — the plugin
  negotiates Docker API v1.53, dockerd caps at v1.41:
  ```bash
  export DOCKER_API_VERSION=$(docker version --format '{{.Server.APIVersion}}')
  ```
  The `docker-compose` v1.25 fallback is too old to parse this file (`mem_limit`).
- **Always `--no-deps` on `--force-recreate zrok`**, or it cascades through `depends_on`
  and bounces Postgres to fix a tunnel.
- **`wsl --shutdown` alone never fixes a NIC-less VM.** If `icssvc` is stopped/wedged,
  WSL cannot build its ICS-type HNS network. Bounce `SharedAccess`+`icssvc` via `sc.exe`
  with settle time, then boot WSL once.
- **Stop the `AutoStartWSL` anchor *before* `wsl --shutdown`**, or it restarts the VM
  within a second — mid-rebuild — leaving eth0 with a dead gateway.
- **Never give a low interface metric to a wired link that is up but has no internet.**
  It blackholes traffic and takes the box off Tailscale entirely.
- SSH over Tailscale is slow: always `-o ConnectTimeout=45`. macOS has no `timeout`.

### Upload limits — what is and isn't true

- Immich sets `server.requestTimeout = 24 * 60 * 60 * 1000` (**24 h**) in
  `/usr/src/app/server/dist/app.common.js`. There is **no 5-minute server cap**.
  (Node's 300 s default is overridden — do not measure it with a fresh `createServer()`.)
- There is **no resumable/chunked upload** in Immich. One file = one HTTP request, and a
  failure restarts from zero.
- Large-upload failures here have been **memory or network**, never an Immich timeout.
- For very large files the official, no-HTTP route is an **External Library** (see §4).

---

## 10. Version history

| Date | Change |
|---|---|
| 2026-03-24 | v2.6.3 released; box stayed on it |
| 2026-06-22 | host OOM incident → `.wslconfig` 4.5 GB + `mem_limit: 1500m` added |
| 2026-08-16→29 | public share 502 for ~13 days (ICS churn → WSL NIC loss) |
| 2026-08-29 | DNS pinned; watchdog v2 (9 layers, escalation, backoff); hotspot cooldown |
| 2026-08-29 | **v2.6.3 → v3.1.0**; ~21 DB migrations, data intact, ML repo error cleared |
| 2026-08-29 | swap actually enabled (4 GB); `immich_server` 1500m→2560m; ML capped 1536m |

Restore from scratch: `git clone` the repo, then
`powershell -ExecutionPolicy Bypass -File .\install.ps1`.
`setup/sync-to-repo.ps1` mirrors the live runtime back into git so this stays true.
