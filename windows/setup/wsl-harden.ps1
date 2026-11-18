# wsl-harden.ps1 - WSL-side network hardening. Idempotent; safe to re-run.
#
# Applies the fixes that keep zrok/Immich reachable. Without these, a fresh install
# reproduces the outage that took this server down for ~13 days in Aug 2026:
#
#   WSL regenerates /etc/resolv.conf pointing at a Windows-side DNS proxy on the
#   vEthernet gateway. That proxy dies whenever the upstream changes (USB modem
#   re-enumerating, hotspot ICS churn). Docker's embedded resolver at 127.0.0.11
#   forwards to it, so every container loses DNS, so zrok cannot reach
#   api-v1.zrok.io, so the public share 502s - while Immich still answers 200 on
#   localhost and every container shows Up, which is what made it so hard to see.
#
# Three independent guards, because they fail independently:
#   1. /etc/resolv.conf pinned to public resolvers and made IMMUTABLE. WSL rewrites
#      it within seconds otherwise; chattr +i makes that rewrite fail harmlessly.
#   2. generateResolvConf=false so WSL stops regenerating it after the next VM boot.
#   3. daemon.json "dns" so CONTAINERS resolve correctly regardless of what the host
#      resolv.conf currently says. This is the one that actually keeps zrok alive.

[CmdletBinding()]
param([string]$Distro = 'Ubuntu-22.04')

$bash = @'
set -u
CHANGED=0

# 1. resolv.conf - real file, public resolvers, immutable.
if ! grep -q '1.1.1.1' /etc/resolv.conf 2>/dev/null; then
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
  printf '%s\n' '# Pinned by wsl-harden.ps1 (immutable). WSL-generated DNS proxy dies when the' > /etc/resolv.conf
  printf '%s\n' '# upstream changes, which silently kills container DNS and therefore zrok.' >> /etc/resolv.conf
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\noptions timeout:2 attempts:2 rotate\n' >> /etc/resolv.conf
  chmod 644 /etc/resolv.conf
  CHANGED=1
  echo "resolv.conf pinned"
fi
chattr +i /etc/resolv.conf 2>/dev/null && echo "resolv.conf immutable" || echo "chattr unsupported"

# 2. wsl.conf - stop WSL regenerating resolv.conf on the next boot.
touch /etc/wsl.conf
if ! grep -q 'generateResolvConf' /etc/wsl.conf 2>/dev/null; then
  printf '\n[network]\ngenerateResolvConf = false\n' >> /etc/wsl.conf
  CHANGED=1
  echo "wsl.conf generateResolvConf=false"
fi

# 3. daemon.json - pin CONTAINER dns. live-restore keeps containers up across a
#    dockerd restart, which is what makes this safe to apply on a running box.
if ! grep -q '"dns"' /etc/docker/daemon.json 2>/dev/null; then
  mkdir -p /etc/docker
  [ -f /etc/docker/daemon.json ] && cp -a /etc/docker/daemon.json /etc/docker/daemon.json.bak-$(date +%s)
  printf '{\n  "live-restore": true,\n  "dns": ["1.1.1.1", "8.8.8.8", "9.9.9.9"]\n}\n' > /etc/docker/daemon.json
  CHANGED=1
  echo "daemon.json dns pinned"
  systemctl restart docker 2>/dev/null || true
  sleep 6
fi

echo "CHANGED=$CHANGED"
getent hosts api-v1.zrok.io >/dev/null 2>&1 && echo "HOST_DNS_OK" || echo "HOST_DNS_FAIL"
'@

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bash))
$out = & wsl.exe -d $Distro -u root -- bash -c "echo $b64 | base64 -d | bash" 2>&1
$out | ForEach-Object { Write-Host ("    " + $_) }

if (($out -join ' ') -match 'HOST_DNS_OK') { Write-Host '    OK  WSL DNS resolves.' -ForegroundColor Green }
else { Write-Host '    !!  WSL DNS still failing - check the upstream link.' -ForegroundColor Yellow }
