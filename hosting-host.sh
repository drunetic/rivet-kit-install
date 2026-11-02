#!/usr/bin/env bash
# ── patch HQ hosting: run once in the Proxmox host's shell, with the key HQ → Hosting shows ─────────
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/drunetic/rivet-kit-install/main/hosting-host.sh)" _ 'ssh-ed25519 AAAA… patch-hq'
#
# Lets HQ's builder make hosted instances on this host, and nothing else. Its key is added to root's
# authorized_keys with a forced command: whatever the builder asks, sshd runs /usr/local/sbin/
# patch-hosting, which knows three requests (ping, ips, provision) and checks every value it is given.
# No shell, no port forwarding, no terminal. Run again with a new key to replace the old one; run with
# `remove` instead of a key to take it away.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }
command -v pct >/dev/null || { echo "This is for a Proxmox VE host."; exit 1; }
KEYS=/root/.ssh/authorized_keys
mkdir -p /root/.ssh; touch "$KEYS"
# Proxmox keeps root's keys in the cluster filesystem (a link to /etc/pve/priv): edit through the link.
drop_old() { local t; t=$(mktemp); grep -v 'patch-hosting' "$KEYS" > "$t" || true; cat "$t" > "$KEYS"; rm -f "$t"; }

if [ "${1:-}" = remove ]; then drop_old; rm -f /usr/local/sbin/patch-hosting; echo "✓ HQ can no longer make hosted instances here."; exit 0; fi
key=${1:-}
printf '%s' "$key" | grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]{60,100}( [A-Za-z0-9@._-]{1,40})?$' || { echo "Give HQ's key, as HQ → Hosting shows it, in single quotes."; exit 1; }

cat > /usr/local/sbin/patch-hosting <<'EOF'
#!/usr/bin/env bash
# patch-hosting: the only thing HQ's builder may run on this host (install/hosting-host.sh).
set -euo pipefail
SOURCE=https://raw.githubusercontent.com/drunetic/rivet-kit-install/main
case "${SSH_ORIGINAL_COMMAND:-}" in
  ping) echo "ok $(hostname) $(pveversion 2>/dev/null | head -1)" ;;
  ips)
    # Running hosted containers on this node and their first address, one "ctid ip" a line.
    pct list | awk 'NR>1 && $2=="running" {print $1}' | while read -r id; do
      pct config "$id" | grep -q '^tags:.*patch-hosted' || continue
      ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}') || true
      [ -n "$ip" ] && echo "$id $ip"
    done ;;
  provision)
    # NAME=value lines on stdin, each checked; anything unknown or malformed stops it.
    NAME=''; URL=''; DISK=''; RAM=''; CORES=''; LICENCE=''; SETUP=''
    n=0
    while IFS= read -r line && [ $n -lt 20 ]; do
      n=$((n + 1)); k=${line%%=*}; v=${line#*=}
      case "$k" in
        NAME) [[ $v =~ ^patch-[a-z][a-z0-9-]{2,50}$ ]] && NAME=$v ;;
        URL) [[ $v =~ ^https://[a-z0-9.-]+$ ]] && URL=$v ;;
        DISK) [[ $v =~ ^[0-9]{1,4}$ ]] && [ "$v" -ge 8 ] && [ "$v" -le 500 ] && DISK=$v ;;
        RAM) [[ $v =~ ^[0-9]{3,6}$ ]] && [ "$v" -ge 1024 ] && [ "$v" -le 65536 ] && RAM=$v ;;
        CORES) [[ $v =~ ^[0-9]{1,2}$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 32 ] && CORES=$v ;;
        LICENCE) [[ $v =~ ^patch_[a-z2-7]{32}$ ]] && LICENCE=$v ;;
        SETUP) [[ $v =~ ^[a-z0-9]{8,40}$ ]] && SETUP=$v ;;
      esac
    done
    for v in NAME URL DISK RAM CORES LICENCE SETUP; do [ -n "${!v}" ] || { echo "patch-hosting: $v missing or not valid"; exit 2; }; done
    t=$(mktemp); curl -fsSL "$SOURCE/proxmox.sh" -o "$t" || { echo "patch-hosting: could not download the installer"; exit 1; }
    PATCH_PLAIN=1 PATCH_UNATTENDED=1 PATCH_LICENCE_KEY=$LICENCE CT_NAME=$NAME CT_DISK=$DISK CT_RAM=$RAM CT_CORES=$CORES \
      PATCH_URL=$URL PATCH_SETUP_CODE=$SETUP PATCH_TRUST_CLOUDFLARE=1 CT_TAGS='patch;patch-hosted' bash "$t" </dev/null && rc=0 || rc=$?
    rm -f "$t"; exit $rc ;;
  *) echo "patch-hosting: only ping, ips and provision"; exit 2 ;;
esac
EOF
chmod 755 /usr/local/sbin/patch-hosting
drop_old
printf 'command="/usr/local/sbin/patch-hosting",restrict %s\n' "$key" >> "$KEYS"
echo "✓ HQ can now make hosted instances on $(hostname). Press Test connection on HQ → Hosting."
