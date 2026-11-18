# PLAN: move WSL off ICS (so the hotspot and Immich can coexist)

Status: **partially done — blocked on the LAN cable.** Attempted 2026-08-29.
Read [`immich-map.md`](./immich-map.md) first for the stack layout.

---

## RESULT OF THE 2026-08-29 ATTEMPT — read this before redoing anything

**The Internal-switch shortcut does NOT work.** WSL rejected it outright:

```
wsl: Failed to configure network (networkingMode Bridged), falling back to networkingMode None
     CreateVm/ConfigureNetworking/HCS/0x803b0002
```

WSL's `networkingMode=bridged` requires an **External** vSwitch bound to a real
physical NIC. Microsoft's docs are right; the "Internal switch + WinNAT" idea that
this plan was originally built around is not viable. Do not retry it.

Because the only Up adapter today is the USB RNDIS modem — which re-enumerates, and
would take the vSwitch down with it — **this is genuinely blocked until the LAN cable
is connected.** Not blocked on effort or cleverness; on hardware.

### What IS done and does not need repeating

| Item | State |
|---|---|
| Hyper-V role | **Enabled** — `vmms` Running/Automatic, `New-VMSwitch`/`Get-VMSwitch` available. Survives reboots. |
| WinNAT | **Works** — `New-NetNat WSLNat` on `192.168.50.0/24`, `Active=True`. Nothing attached to it yet. |
| `WSLNat` Internal vSwitch | Created, `vEthernet (WSLNat)` = `192.168.50.1/24`. Harmless; keep or remove. |
| `.wslconfig` `swapFile` | **Bug fixed** — see below. |
| `HOTSPOT_DISABLED` opt-out | **Implemented** — see below. |

### Two real bugs found and fixed along the way

1. **`swapFile` was malformed.** It had been "fixed" earlier to
   `swapFile=D:\wsl-swap.vhdx`, but WSL's config parser treats `\w` as an escape:
   ```
   wsl: Invalid escaped character: 'w' in C:\Users\ted\.wslconfig:13
   ```
   Correct value is a **double** backslash: `swapFile=D:\\wsl-swap.vhdx`.
   Verified afterwards: `Swap: 4096` active. (The original `C:\\wsl-swap.vhdx` was
   right about escaping and wrong only about the drive — C: was full.)

2. **The hotspot opt-out was being overridden in two places.** `AutoHotspotHealth` had
   been disabled deliberately, but `Ensure-HotspotTaskEnabled` re-enabled it every
   watchdog cycle, and `Repair-WslNetwork`'s `finally` re-enabled it again — so the AP
   kept coming back and churning ICS, triggering repeated `L2b_wslnet` repairs.
   Both now honour `C:\home-server\state\HOTSPOT_DISABLED`.
   PowerShell gotcha hit while fixing this: **you cannot `return` from a `finally`
   block** ("Flow of control cannot leave a Finally block") — use if/else.

---

## When the LAN cable arrives — the actual fix

Hyper-V is already installed, so this is a short job:

```powershell
# External switch bound to the WIRED NIC (Intel I219-LM, currently Disconnected)
New-VMSwitch -Name WSLBridge -NetAdapterName 'Ethernet' -AllowManagementOS $true

# .wslconfig
#   [wsl2]
#   memory=4500MB
#   swap=4GB
#   swapFile=D:\\wsl-swap.vhdx     <- DOUBLE backslash, see above
#   networkingMode=bridged
#   vmSwitch=WSLBridge

wsl --shutdown
```

Then WSL sits on the LAN with its own address, entirely off ICS, and the hotspot can
own ICS uncontested. Remove the `HOTSPOT_DISABLED` flag and re-enable
`AutoHotspotHealth`.

With bridged + External there is DHCP from the LAN, so no static-IP work is needed —
that concern only applied to the Internal-switch approach.

WinNAT (`WSLNat`) becomes unnecessary at that point and can be removed, or kept
harmlessly.

### Acceptance test

- Hotspot `On` **and** `Test-WslNetwork` = egress 301 **simultaneously**
- `zrok=200` from an external host
- Phone reaches `http://<new WSL LAN IP>:2283` — note the portproxy target changes;
  `Ensure-PortProxy` should correct it automatically, **verify that it does**
- Both survive 15 min with `AutoHotspotHealth` enabled and running every 60s

### Rollback

```powershell
# .wslconfig: delete networkingMode + vmSwitch lines -> back to NAT/ICS
Remove-VMSwitch -Name WSLBridge -Force
wsl --shutdown
```

---

## Until then: the operating reality

The hotspot and Immich **cannot both be relied on**. Current deliberate state:

- `HOTSPOT_DISABLED` flag set, `AutoHotspotHealth` disabled, AP off
- Immich + zrok healthy

Re-enabling the AP will churn ICS and can take WSL's network down. Note also that the
network has been observed dropping **with the hotspot fully off**, so the USB tether
re-enumerating is an independent fault — the hotspot aggravates it rather than solely
causing it. No NAT design fixes a flapping upstream; the LAN cable is the real cure.

## Reboot discipline (learned the hard way)

- Checkpoint Postgres first:
  `docker exec immich_postgres psql -U postgres -d immich -c "CHECKPOINT;"`
- Then `wsl --shutdown` so containers stop cleanly
- Recovery is covered: `AutoStartWSL` is **S4U + AtStartup** (verified firing at boot
  with no login), `sshd` and Tailscale are Automatic, containers are `restart:always`
- **USB tethering does NOT survive a host reboot** — Android drops it and it must be
  re-enabled by hand on the phone. Without it: no internet, no Tailscale, no SSH.
  Budget for physical access.
- Reboots have taken ~10-15 min on this box.
- **Parse-gate PowerShell before promoting it live.** Copy the candidate to
  `state\*.candidate.ps1`, run `[Parser]::ParseFile` against it, and only then copy
  over `lib\`. A broken `immich-guard.ps1` disables every repair the watchdog has.
