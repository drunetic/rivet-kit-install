#!/usr/bin/env bash
# ── patch. for Proxmox VE: one line in the Proxmox host's shell ────────────────────────────
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/drunetic/rivet-kit-install/main/proxmox.sh)"
#
# Creates an unprivileged Debian LXC container with Docker in it, then runs install.sh inside.
# Nothing is installed on the Proxmox host itself: Docker on a hypervisor rewrites its firewall
# and can cut the other guests off the network.
set -euo pipefail

SOURCE=${PATCH_SOURCE:-https://raw.githubusercontent.com/drunetic/rivet-kit-install/main}
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say() { printf '  %s\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ask() {  # ask VAR "Question" [default] [secret]
  local __v=$1 __q=$2 __d=${3:-} __s=${4:-} __a
  if [ -n "${!__v:-}" ]; then return; fi
  if [ -n "$__s" ]; then read -rsp "  $__q (hidden as you type): " __a </dev/tty; echo
  elif [ -n "$__d" ]; then read -rp "  $__q [$__d]: " __a </dev/tty; else read -rp "  $__q: " __a </dev/tty; fi
  printf -v "$__v" '%s' "${__a:-$__d}"
}

command -v pct >/dev/null && command -v pveam >/dev/null || die "This is for the Proxmox host's shell. On any other Debian/Ubuntu machine use install.sh."
[ "$(id -u)" = 0 ] || die "Run as root."
bold "patch. for Proxmox"
say "This creates a small container for patch. Press Enter to accept a [default]."
echo

CTID_DEFAULT=$(pvesh get /cluster/nextid)
ROOT_STORAGE_DEFAULT=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
TMPL_STORAGE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
[ -n "$TMPL_STORAGE" ] || die "No storage on this host accepts container templates (vztmpl)."

ask CTID "Container ID" "$CTID_DEFAULT"
ask CT_NAME "Name" "patch"
ask CT_STORAGE "Storage for its disk" "${ROOT_STORAGE_DEFAULT:-local-lvm}"
ask CT_DISK "Disk size in GB (photos are what grow)" "16"
ask CT_RAM "Memory in MB" "2048"
ask CT_CORES "CPU cores" "2"
ask CT_BRIDGE "Network bridge" "vmbr0"
echo
say "patch is private: you need the access code you were given (it starts ghp_)."
ask PATCH_ACCESS_CODE "Access code" "" secret
[ -n "$PATCH_ACCESS_CODE" ] || die "An access code is needed."
echo
say "How will people reach it?"
say "  1) Only on this network            (you can add remote access later: patchctl tunnel)"
say "  2) From anywhere, via a Cloudflare Tunnel (needed for the phone camera scanner)"
ask MODE "Choose 1 or 2" 1
PATCH_TUNNEL=''; PATCH_URL=''
if [ "$MODE" = 2 ]; then
  say "In Cloudflare: Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared → Docker."
  say "Copy the whole 'docker run …' command it shows and paste it here."
  ask PATCH_TUNNEL "Cloudflare's command"
  ask PATCH_URL "The address you will give it in Cloudflare, e.g. kit.yourdomain.co.uk"
fi

# ── Template ────────────────────────────────────────────────────────────────────────────────────
say "Finding the Debian template…"
pveam update >/dev/null 2>&1 || true
# awk, not grep: under pipefail a grep with no match would end the script silently.
TEMPLATE=$(pveam available --section system 2>/dev/null | awk '$2 ~ /^debian-13-standard/ {print $2}' | sort -V | tail -1)
[ -n "$TEMPLATE" ] || TEMPLATE=$(pveam available --section system 2>/dev/null | awk '$2 ~ /^debian-12-standard/ {print $2}' | sort -V | tail -1)
[ -n "$TEMPLATE" ] || die "Could not find a Debian template (pveam available)."
pveam list "$TMPL_STORAGE" | awk -v t="$TEMPLATE" 'index($1, t) {f=1} END {exit !f}' || { say "Downloading $TEMPLATE…"; pveam download "$TMPL_STORAGE" "$TEMPLATE" >/dev/null; }

# ── Container ───────────────────────────────────────────────────────────────────────────────────
say "Creating container $CTID ($CT_NAME)…"
# Unprivileged, with nesting and keyctl: what Docker needs inside an LXC, and no more.
pct create "$CTID" "$TMPL_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$CT_NAME" --cores "$CT_CORES" --memory "$CT_RAM" --swap 512 \
  --rootfs "$CT_STORAGE:$CT_DISK" --net0 "name=eth0,bridge=$CT_BRIDGE,ip=dhcp" \
  --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 --ostype debian \
  --tags patch --description "patch. Manage from inside: pct enter $CTID, then patchctl help" >/dev/null
pct start "$CTID"

say "Waiting for its network…"
for i in $(seq 1 60); do
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  [ "$i" = 60 ] && die "Container $CTID has no network after two minutes. Check the bridge ($CT_BRIDGE) and DHCP."
  sleep 2
done

say "Preparing it (a few minutes)…"
pct exec "$CTID" -- bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates >/dev/null"
pct exec "$CTID" -- bash -c "curl -fsSL '$SOURCE/install.sh' -o /root/install.sh"

# Answers go in as environment variables: pct exec gives the installer no terminal to ask on. They
# are exported rather than put on the command line (pct exec passes the environment through), so
# the access code and tunnel token never appear in the host's process list.
export PATCH_ACCESS_CODE PATCH_TUNNEL PATCH_URL PATCH_SOURCE="$SOURCE"
pct exec "$CTID" -- bash /root/install.sh || {
  echo
  say "The install inside the container stopped. Its output is above."
  say "If it mentions 'ip_unprivileged_port_start' or 'permission denied' starting containers, this"
  say "Proxmox host needs its updates (apt full-upgrade, then reboot); Docker in LXC needed a fix there."
  say "Then run it again inside the container:  pct enter $CTID   then   bash /root/install.sh"
  exit 1
}

IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo
bold "✓ Container $CTID is running patch at http://$IP:3000"
say "Give it a fixed address: reserve $IP for '$CT_NAME' on your router."
say "Manage it from here:  pct enter $CTID   then   patchctl help"
