#!/usr/bin/env bash
# ── patch. for Proxmox VE: one line in the Proxmox host's shell ────────────────────────────
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/drunetic/rivet-kit-install/main/proxmox.sh)"
#
# With PATCH_ROLE=hq in front it makes patch HQ instead (the box that builds patch and hands out
# updates; docs/hq.md): a bigger container, a GitHub token rather than an access code, and
# hq-install.sh inside rather than install.sh.
#
# Creates an unprivileged Debian LXC container with Docker in it, then runs install.sh inside.
# Nothing is installed on the Proxmox host itself: Docker on a hypervisor rewrites its firewall
# and can cut the other guests off the network.
set -euo pipefail

SOURCE=${PATCH_SOURCE:-https://raw.githubusercontent.com/drunetic/rivet-kit-install/main}
ROLE=${PATCH_ROLE:-}
[ -z "$ROLE" ] || [ "$ROLE" = hq ] || { echo "PATCH_ROLE is either hq or not set."; exit 1; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say() { printf '  %s\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# Questions in proper boxes (whiptail, which every Proxmox host has) when there is a terminal, plain
# prompts otherwise or with PATCH_PLAIN=1. Answers already in the environment are never asked.
# Opening /dev/tty is the test: it can exist, and read as readable, with no terminal behind it.
UI=$( command -v whiptail >/dev/null 2>&1 && { : </dev/tty; } 2>/dev/null && [ -z "${PATCH_PLAIN:-}" ] && echo 1 || true )
BOX="patch."
box() { whiptail --backtitle "patch. for Proxmox" --title "$BOX" "$@" 3>&1 1>&2 2>&3 </dev/tty; }
ask() {  # ask VAR "Question" [default] [secret]
  local __v=$1 __q=$2 __d=${3:-} __s=${4:-} __a
  if [ -n "${!__v:-}" ]; then return; fi
  if [ -n "$UI" ]; then
    if [ -n "$__s" ]; then __a=$(box --passwordbox "$__q" 10 72) || die "Cancelled. Nothing was made."
    else __a=$(box --inputbox "$__q" 10 72 "$__d") || die "Cancelled. Nothing was made."; fi
  elif [ -n "$__s" ]; then read -rsp "  $__q (hidden as you type): " __a </dev/tty; echo
  elif [ -n "$__d" ]; then read -rp "  $__q [$__d]: " __a </dev/tty; else read -rp "  $__q: " __a </dev/tty; fi
  printf -v "$__v" '%s' "${__a:-$__d}"
}
choose() {  # choose VAR "Question" DEFAULT  KEY "Label" [KEY "Label" …]
  local __v=$1 __q=$2 __d=$3 __a; shift 3
  if [ -n "${!__v:-}" ]; then return; fi
  if [ -n "$UI" ]; then
    __a=$(box --default-item "$__d" --notags --menu "$__q" 14 76 $(( $# / 2 )) "$@") || die "Cancelled. Nothing was made."
  else
    say "$__q"; while [ $# -gt 0 ]; do say "  $1) $2"; shift 2; done
    read -rp "  Choose [$__d]: " __a </dev/tty
  fi
  printf -v "$__v" '%s' "${__a:-$__d}"
}
# The HQ these installers are published by: a licence key is all a customer is asked for.
BUILT_IN_HQ=${PATCH_BUILT_IN_HQ:-https://hq.andrewhaslam.co.uk}

command -v pct >/dev/null && command -v pveam >/dev/null || die "This is for the Proxmox host's shell. On any other Debian/Ubuntu machine use install.sh."
[ "$(id -u)" = 0 ] || die "Run as root."
if [ "$ROLE" = hq ]; then
  bold "patch HQ for Proxmox"
  say "This creates the container that builds patch and hands out its updates. Press Enter to accept a [default]."
  # HQ's questions come with instructions printed above them, which a box would hide.
  UI=''
  # Building patch wants memory and cores; every release ever built is kept in the image store.
  NAME_D=patch-hq; DISK_D=60; RAM_D=4096; CORES_D=4
else
  bold "patch. for Proxmox"
  say "This creates a small container for patch. Only the licence key is asked; the rest is in your browser afterwards."
  NAME_D='patch'; DISK_D=16; RAM_D=2048; CORES_D=2
fi
echo

CTID_DEFAULT=$(pvesh get /cluster/nextid)
ROOT_STORAGE_DEFAULT=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
TMPL_STORAGE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
[ -n "$TMPL_STORAGE" ] || die "No storage on this host accepts container templates (vztmpl)."

# Licence first: a wrong key is said before anything is made.
PATCH_TUNNEL=${PATCH_TUNNEL:-}; PATCH_URL=${PATCH_URL:-}; PATCH_IMAGES_URL=''; GITHUB_TOKEN=${GITHUB_TOKEN:-}; PATCH_ACCESS_CODE=${PATCH_ACCESS_CODE:-}
PATCH_LICENCE_KEY=${PATCH_LICENCE_KEY:-}; PATCH_HQ_URL=${PATCH_HQ_URL:-}
if [ "$ROLE" != hq ]; then
  KEY_GIVEN=${KEY_IN:+1}${PATCH_LICENCE_KEY:+1}; KEY_IN=${KEY_IN:-$PATCH_LICENCE_KEY}
  # Always https, however it was given: the key crosses the internet in a header.
  HQ_GIVEN=$(printf '%s' "${PATCH_HQ_URL:-$BUILT_IN_HQ}" | tr -d '[:space:]' | sed -E 's#^[A-Za-z]+://##; s#/.*$##' | tr 'A-Z' 'a-z')
  printf '%s' "$HQ_GIVEN" | grep -Eq '^[a-z0-9.-]+(:[0-9]{1,5})?$' || die "HQ's address ($HQ_GIVEN) is not an address like hq.example.co.uk."
  HQ_GIVEN="https://$HQ_GIVEN"
  while :; do
    ask KEY_IN "Your licence key. It starts patch_ and came with your welcome email." "" secret
    KEY_IN=$(printf '%s' "${KEY_IN:-}" | tr -d '[:space:]')
    case "$KEY_IN" in
      # An access code (ghp_…) still works, for an install that is not licensed through HQ yet.
      ghp_*) PATCH_ACCESS_CODE=$KEY_IN; break ;;
      patch_*)
        PATCH_LICENCE_KEY=$KEY_IN; PATCH_HQ_URL=$HQ_GIVEN
        # A check only: HQ records nothing. The key goes in a header from stdin, never on a command line.
        answer=$(printf 'Authorization: Bearer %s\n' "$KEY_IN" | curl -sS -m 20 -X POST -H @- -H 'Content-Type: application/json' \
          --data '{"check":true}' -w '\n%{http_code}' "$PATCH_HQ_URL/api/hq/m/checkin" 2>/dev/null || true)
        code=$(printf '%s' "$answer" | tail -1); body=$(printf '%s' "$answer" | sed '$d')
        status=$(printf '%s' "$body" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p'); company=$(printf '%s' "$body" | sed -n 's/.*"company":"\([^"]*\)".*/\1/p')
        if [ "$code" = 200 ] && [ "$status" = valid ]; then say "✓ Licensed to $company"; break; fi
        why=$( [ "$code" = 401 ] && echo "HQ does not know that key. Check it was copied whole." \
          || { [ "$code" = 200 ] && echo "That licence ($company) is not current ($status)."; } \
          || echo "Could not reach HQ at $PATCH_HQ_URL (answered ${code:-nothing}). Check this host is online." ) ;;
      '') why="A licence key is needed." ;;
      *) why="That does not look like a licence key (they start patch_)." ;;
    esac
    # A key given in the environment is not asked again: stop rather than loop.
    [ -n "$UI" ] && [ -z "$KEY_GIVEN" ] || die "$why"
    box --msgbox "$why" 9 72 || true
    unset KEY_IN; PATCH_LICENCE_KEY=''; PATCH_HQ_URL=$HQ_GIVEN
  done
fi

STORAGE_D=${ROOT_STORAGE_DEFAULT:-local-lvm}
# Not asked when the container's settings were given in the environment (a scripted run), nor when
# HQ is making a hosted instance (PATCH_UNATTENDED, from install/hosting-host.sh): defaults for the rest.
[ -n "${PATCH_UNATTENDED:-}" ] && SETUP=1
[ -n "${CTID:-}" ] && SETUP=${SETUP:-advanced}
choose SETUP "How should the container be made?" 1 \
  1 "Defaults: ID $CTID_DEFAULT, ${DISK_D} GB disk on $STORAGE_D, $((RAM_D / 1024)) GB memory, $CORES_D cores, DHCP" \
  2 "Advanced: choose each of these"
case "$SETUP" in 1|d*|D*) SETUP=defaults ;; *) SETUP=advanced ;; esac
if [ "$SETUP" = defaults ]; then
  CTID=${CTID:-$CTID_DEFAULT}; CT_NAME=${CT_NAME:-$NAME_D}; CT_STORAGE=${CT_STORAGE:-$STORAGE_D}; CT_DISK=${CT_DISK:-$DISK_D}
  CT_RAM=${CT_RAM:-$RAM_D}; CT_CORES=${CT_CORES:-$CORES_D}; CT_BRIDGE=${CT_BRIDGE:-vmbr0}; NET_MODE=${NET_MODE:-1}
fi
ask CTID "Container ID" "$CTID_DEFAULT"
ask CT_NAME "Name" "$NAME_D"
ask CT_STORAGE "Storage for its disk" "$STORAGE_D"
ask CT_DISK "Disk size in GB ($([ "$ROLE" = hq ] && echo 'every release is kept' || echo 'photos are what grow'))" "$DISK_D"
ask CT_RAM "Memory in MB" "$RAM_D"
ask CT_CORES "CPU cores" "$CORES_D"
ask CT_BRIDGE "Network bridge" "vmbr0"
echo
# Its address is settled here, before anything is installed: with no tunnel, patch records the
# address it is reached on (for links in emails and on labels), so it must not change later.
choose NET_MODE "Its address on your network:" 1 \
  1 "Automatic (DHCP): reserve it on your router afterwards" \
  2 "Fixed: you choose it now"
CT_IP=dhcp; CT_GW=''
if [ "$NET_MODE" = 2 ]; then
  GW_DEFAULT=$(ip -4 route show default dev "$CT_BRIDGE" 2>/dev/null | awk '{print $3; exit}' || true)
  HOST_PREFIX=$(ip -4 -o addr show dev "$CT_BRIDGE" 2>/dev/null | awk '{split($4, a, "/"); print a[2]; exit}' || true)
  while :; do
    ask CT_IP_IN "Address, e.g. 192.168.1.50"
    CT_IP=$CT_IP_IN; unset CT_IP_IN
    # A bare address takes the host's own network size (/24 on most home networks).
    case "$CT_IP" in */*) ;; *) CT_IP="$CT_IP/${HOST_PREFIX:-24}" ;; esac
    if ! printf '%s' "$CT_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then say "That is not an address like 192.168.1.50."; continue; fi
    # Something already answering there would fight the container for the address.
    if ping -c1 -W1 "${CT_IP%/*}" >/dev/null 2>&1; then say "Something on your network already answers at ${CT_IP%/*}. Choose another."; continue; fi
    break
  done
  ask CT_GW "Gateway (your router)" "$GW_DEFAULT"
  [ -n "$CT_GW" ] || die "A gateway is needed for a fixed address."
fi
NET0="name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP${CT_GW:+,gw=$CT_GW}"
# A container copies the host's DNS servers unless told otherwise. Some only work on the host
# itself: Tailscale's 100.100.100.100 (MagicDNS) and local resolvers on 127.x. Inside the container
# those fail, or work only now and then, and patch cannot reach GitHub to check for updates.
CT_DNS=''
if awk '$1=="nameserver" {print $2}' /etc/resolv.conf 2>/dev/null | grep -Eq '^(100\.100\.100\.100|127\.|::1$|fd7a:115c:a1e0:)'; then
  CT_DNS="1.1.1.1 9.9.9.9"
  say "This host's DNS only works on the host (Tailscale or a local resolver), so the container uses $CT_DNS."
fi
echo
if [ "$ROLE" = hq ]; then
  say "HQ builds patch from its code, so it needs a GitHub token that can only read it:"
  say "GitHub → Settings → Developer settings → Fine-grained tokens; repository drunetic/Rivet-Kit only,"
  say "permission Contents: Read-only."
  ask GITHUB_TOKEN "GitHub token" "" secret
  [ -n "$GITHUB_TOKEN" ] || die "A GitHub token is needed."
  echo
  say "Installs reach HQ through a Cloudflare Tunnel on two addresses (HQ's, and one for images)."
  choose MODE "Installs reach HQ through a Cloudflare Tunnel. Set it up now?" 1 \
    1 "Not yet: add it later inside the container (patchctl tunnel)" \
    2 "Now: Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared → Docker"
  if [ "$MODE" = 2 ]; then
    ask PATCH_TUNNEL "Cloudflare's 'docker run …' command"
    ask PATCH_URL "HQ's address, e.g. hq.yourdomain.co.uk"
    ask PATCH_IMAGES_URL "The images address, e.g. images.yourdomain.co.uk"
  fi
fi

# ── Template ────────────────────────────────────────────────────────────────────────────────────
# The host's language settings pass into the container through pct exec, where Debian has none of
# them installed and every apt and perl step complains. Plain UTF-8 is there in any Debian.
export LC_ALL=C.UTF-8
say "Finding the Debian template…"
pveam update >/dev/null 2>&1 || true
# awk, not grep: under pipefail a grep with no match would end the script silently.
# The template for THIS host's processor: Proxmox now lists arm64 templates too, and one of those on
# an Intel/AMD host makes a container that cannot start ("Failed to spawn container").
ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
TEMPLATE=$(pveam available --section system 2>/dev/null | awk -v a="_$ARCH." '$2 ~ /^debian-13-standard/ && index($2, a) {print $2}' | sort -V | tail -1)
[ -n "$TEMPLATE" ] || TEMPLATE=$(pveam available --section system 2>/dev/null | awk -v a="_$ARCH." '$2 ~ /^debian-12-standard/ && index($2, a) {print $2}' | sort -V | tail -1)
[ -n "$TEMPLATE" ] || die "Could not find a Debian template (pveam available)."
pveam list "$TMPL_STORAGE" | awk -v t="$TEMPLATE" 'index($1, t) {f=1} END {exit !f}' || { say "Downloading $TEMPLATE…"; pveam download "$TMPL_STORAGE" "$TEMPLATE" >/dev/null; }

# ── Container ───────────────────────────────────────────────────────────────────────────────────
say "Creating container $CTID ($CT_NAME)…"
# Unprivileged, with nesting and keyctl: what Docker needs inside an LXC, and no more.
pct create "$CTID" "$TMPL_STORAGE:vztmpl/$TEMPLATE" --arch "$ARCH" \
  --hostname "$CT_NAME" --cores "$CT_CORES" --memory "$CT_RAM" --swap 512 \
  --rootfs "$CT_STORAGE:$CT_DISK" --net0 "$NET0" \
  ${CT_DNS:+--nameserver "$CT_DNS"} \
  --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 --ostype debian \
  --tags "${CT_TAGS:-patch${ROLE:+-$ROLE}}" --description "patch. Manage from inside: pct enter $CTID, then patchctl help" >/dev/null
pct start "$CTID"

say "Waiting for its network…"
for i in $(seq 1 60); do
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  [ "$i" = 60 ] && die "Container $CTID has no network after two minutes. Check the bridge ($CT_BRIDGE)$([ "$CT_IP" = dhcp ] && echo ' and DHCP' || echo ", the address $CT_IP and the gateway $CT_GW")."
  sleep 2
done

say "Preparing it (a few minutes)…"
pct exec "$CTID" -- bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates qrencode >/dev/null"
INSTALLER=$([ "$ROLE" = hq ] && echo hq-install.sh || echo install.sh)
pct exec "$CTID" -- bash -c "curl -fsSL '$SOURCE/$INSTALLER' -o /root/install.sh"

# Answers go in as environment variables: pct exec gives the installer no terminal to ask on. They
# are exported rather than put on the command line (pct exec passes the environment through), so
# the access code and tunnel token never appear in the host's process list.
PATCH_SETUP_CODE=${PATCH_SETUP_CODE:-}; PATCH_TRUST_CLOUDFLARE=${PATCH_TRUST_CLOUDFLARE:-}
export PATCH_ACCESS_CODE PATCH_LICENCE_KEY PATCH_HQ_URL PATCH_TUNNEL PATCH_URL PATCH_IMAGES_URL GITHUB_TOKEN PATCH_SETUP_CODE PATCH_TRUST_CLOUDFLARE PATCH_SOURCE="$SOURCE"
pct exec "$CTID" -- bash /root/install.sh || {
  echo
  say "The install inside the container stopped. Its output is above."
  say "If it mentions 'ip_unprivileged_port_start' or 'permission denied' starting containers, this"
  say "Proxmox host needs its updates (apt full-upgrade, then reboot); Docker in LXC needed a fix there."
  say "Then run it again inside the container:  pct enter $CTID   then   bash /root/install.sh"
  exit 1
}

IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
# For HQ's builder, which reads this line to know what was made (scripts/builder.sh).
[ -n "${PATCH_UNATTENDED:-}" ] && echo "PATCH_RESULT ctid=$CTID ip=$IP"
echo
bold "✓ Container $CTID is running $([ "$ROLE" = hq ] && echo 'patch HQ' || echo patch) at http://$IP:3000"
if [ "$ROLE" != hq ]; then
  # The QR code for a phone is printed by install.sh, above.
  say "Open that address to finish setting up: your account, then remote access."
fi
[ "$CT_IP" = dhcp ] && say "Give it a fixed address: reserve $IP for '$CT_NAME' on your router."
say "Manage it from here:  pct enter $CTID   then   patchctl help"
