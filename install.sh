#!/usr/bin/env bash
# ── Rivet Kit installer for any Debian or Ubuntu machine (VM, LXC, mini PC, Hyper-V guest) ─────
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/drunetic/rivet-kit-install/main/install.sh)"
#
# Installs Docker if it is missing, asks for the business's access code and how Rivet Kit will be
# reached, writes /opt/rivet-kit/{docker-compose.yml,.env}, starts it, and adds the `rivetkit`
# command for later jobs (update, backup, tunnel, logs). Safe to run again: an existing .env is kept.
#
# Non-interactive (the Proxmox script uses this): set RK_ACCESS_CODE, and optionally RK_TUNNEL
# (Cloudflare's whole "docker run … --token …" command, or just the token), RK_URL, RK_PORT, RK_DIR.
set -euo pipefail

SOURCE=${RK_SOURCE:-https://raw.githubusercontent.com/drunetic/rivet-kit-install/main}
DIR=${RK_DIR:-/opt/rivet-kit}
REGISTRY_USER=${RK_REGISTRY_USER:-drunetic}
PORT=${RK_PORT:-3000}

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say() { printf '  %s\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ask() {  # ask VAR "Question" [default] [secret] — reads the terminal even when piped through curl
  local __v=$1 __q=$2 __d=${3:-} __s=${4:-} __a
  if [ -n "${!__v:-}" ]; then return; fi
  [ -r /dev/tty ] || die "No terminal to ask \"$__q\". Set $__v and run again."
  if [ -n "$__s" ]; then read -rsp "  $__q (hidden as you type): " __a </dev/tty; echo
  elif [ -n "$__d" ]; then read -rp "  $__q [$__d]: " __a </dev/tty; else read -rp "  $__q: " __a </dev/tty; fi
  printf -v "$__v" '%s' "${__a:-$__d}"
}
setenv() {  # setenv NAME value — replaces the line in .env, or adds it, keeping the file's mode
  local tmp; tmp=$(mktemp)
  grep -v "^$1=" .env > "$tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  cat "$tmp" > .env && rm -f "$tmp"
}
token_from() {  # accepts Cloudflare's whole docker command or the bare token
  printf '%s' "$1" | sed 's/.*--token[[:space:]]*//' | tr -d '[:space:]'
}

[ "$(id -u)" = 0 ] || die "Run this as root (on Debian: su - first)."
bold "Rivet Kit installer"

# ── Docker ──────────────────────────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  say "Installing Docker (from Docker's own repository)…"
  command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null; }
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker info >/dev/null 2>&1 || die "Docker is installed but not running. Check: systemctl status docker"

# ── Access code ─────────────────────────────────────────────────────────────────────────────────
echo
say "Rivet Kit is private. You need the access code you were given (it starts ghp_)."
ask RK_ACCESS_CODE "Access code" "" secret
[ -n "$RK_ACCESS_CODE" ] || die "An access code is needed to download Rivet Kit."
printf '%s' "$RK_ACCESS_CODE" | docker login ghcr.io -u "$REGISTRY_USER" --password-stdin >/dev/null 2>&1 \
  || die "That access code was not accepted. Check it was copied whole, or ask for a new one."
say "✓ Access code accepted"

# ── How it will be reached ──────────────────────────────────────────────────────────────────────
mkdir -p "$DIR"
cd "$DIR"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -f .env ]; then
  say "Keeping the existing settings in $DIR/.env"
  # …except the access code just given, or Settings → Updates would keep using a revoked one.
  setenv RIVET_ACCESS_CODE "$RK_ACCESS_CODE"
else
  if [ -z "${RK_TUNNEL+x}" ]; then
    echo
    say "How will people reach Rivet Kit?"
    say "  1) Only on this network, at http://$IP:$PORT   (you can add remote access later: rivetkit tunnel)"
    say "  2) From anywhere, through a Cloudflare Tunnel   (needed for the phone camera scanner)"
    ask MODE "Choose 1 or 2" 1
    RK_TUNNEL=''
    if [ "$MODE" = 2 ]; then
      say "In Cloudflare: Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared → Docker."
      say "Copy the whole 'docker run …' command it shows and paste it here."
      ask RK_TUNNEL "Cloudflare's command"
    fi
  fi
  TUNNEL_TOKEN=$( [ -n "$RK_TUNNEL" ] && token_from "$RK_TUNNEL" || true )
  if [ -n "$TUNNEL_TOKEN" ]; then
    case "$TUNNEL_TOKEN" in eyJ*) ;; *) die "That does not look like a tunnel token (they start eyJ)." ;; esac
    ask RK_URL "The address you will give it in Cloudflare, e.g. kit.yourdomain.co.uk"
    RK_URL="https://${RK_URL#https://}"; RK_URL=${RK_URL%/}
  else
    RK_URL=${RK_URL:-http://$IP:$PORT}
  fi
  umask 077
  cat > .env <<EOF
# Rivet Kit settings for this install. Keep a copy somewhere safe (a password manager).
# Change with the rivetkit command (rivetkit help) or edit here and run: rivetkit restart
POSTGRES_PASSWORD=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
RIVET_ACCESS_CODE=$RK_ACCESS_CODE
PUBLIC_BASE_URL=$RK_URL
APP_PORT=$PORT
TZ=${TZ:-Europe/London}
TRUST_CLOUDFLARE_HEADERS=$([ -n "$TUNNEL_TOKEN" ] && echo 1 || echo 0)
COMPOSE_PROFILES=$([ -n "$TUNNEL_TOKEN" ] && echo tunnel || true)
TUNNEL_TOKEN=$TUNNEL_TOKEN
EOF
  umask 022
fi

# ── Files and start ─────────────────────────────────────────────────────────────────────────────
curl -fsSL "$SOURCE/docker-compose.yml" -o docker-compose.yml.new && mv docker-compose.yml.new docker-compose.yml
curl -fsSL "$SOURCE/rivetkit" -o /usr/local/bin/rivetkit && chmod +x /usr/local/bin/rivetkit
# Backups hold the database and the app's own secrets: root only.
mkdir -p backups && chmod 0700 backups
PORT=$(grep '^APP_PORT=' .env | cut -d= -f2- || true); PORT=${PORT:-3000}
echo
say "Downloading Rivet Kit (a minute or two the first time)…"
docker compose pull -q
docker compose up -d --remove-orphans

say "Starting…"
for _ in $(seq 1 60); do
  if curl -fsS -m 3 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    URL=$(grep '^PUBLIC_BASE_URL=' .env | cut -d= -f2-)
    echo
    bold "✓ Rivet Kit is running"
    say "On this network:  http://$IP:$PORT"
    [ "${URL#https://}" != "$URL" ] && say "From anywhere:    $URL   (once the hostname is added in Cloudflare)"
    say "Open it and the setup page makes the first account."
    say "Later jobs: rivetkit update | backup | tunnel | logs | status   (rivetkit help)"
    exit 0
  fi
  sleep 3
done
die "Rivet Kit did not answer within three minutes. See: rivetkit logs"
