#!/usr/bin/env bash
# ── patch. installer for any Debian or Ubuntu machine (VM, LXC, mini PC, Hyper-V guest) ─────
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/drunetic/rivet-kit-install/main/install.sh)"
#
# Installs Docker if it is missing, asks for the company's licence key (or an older access code),
# writes /opt/patch/{docker-compose.yml,.env}, starts it, and adds the `patchctl`
# command for later jobs (update, backup, tunnel, logs). Safe to run again: an existing .env is kept.
# (`patchctl`, not `patch`: /usr/bin/patch is the standard diff tool that apt and friends rely on.)
#
# Everything else (remote access, the first account) is done in the browser afterwards (0.75).
#
# Non-interactive (the Proxmox script uses this): set PATCH_LICENCE_KEY and PATCH_HQ_URL (or, for an
# install still on GitHub's registry, PATCH_ACCESS_CODE), and optionally PATCH_TUNNEL
# (Cloudflare's whole "docker run … --token …" command, or just the token), PATCH_URL, PATCH_PORT, PATCH_DIR.
set -euo pipefail

SOURCE=${PATCH_SOURCE:-https://raw.githubusercontent.com/drunetic/rivet-kit-install/main}
# /opt/patch, or /opt/rivet-kit for an install from before the rename, so running this again on one
# updates it rather than starting a second, empty install beside it (patchctl chooses the same way).
DIR=${PATCH_DIR:-$( [ -d /opt/patch ] || [ ! -d /opt/rivet-kit ] && echo /opt/patch || echo /opt/rivet-kit )}
REGISTRY_USER=${PATCH_REGISTRY_USER:-drunetic}
# The HQ these installers are published by, so a licence key is all anyone is asked for.
BUILT_IN_HQ=${PATCH_BUILT_IN_HQ:-https://hq.andrewhaslam.co.uk}
PORT=${PATCH_PORT:-3000}

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
  # It holds the database password and licence key: whoever made it, only root reads it.
  chmod 600 .env
}
hq_url() {  # "HTTPS://Hq.X/path/", "hq.x" or "http://hq.x" → https://hq.x (always https: the key crosses the internet)
  local h; h=$(printf '%s' "$1" | tr -d '[:space:]' | sed -E 's#^[A-Za-z]+://##; s#/.*$##' | tr 'A-Z' 'a-z')
  printf '%s' "$h" | grep -Eq '^[a-z0-9.-]+(:[0-9]{1,5})?$' || return 1
  printf 'https://%s' "$h"
}
token_from() {  # accepts Cloudflare's whole docker command or the bare token
  printf '%s' "$1" | sed 's/.*--token[[:space:]]*//' | tr -d '[:space:]'
}

[ "$(id -u)" = 0 ] || die "Run this as root (on Debian: su - first)."
bold "patch. installer"

# ── Docker ──────────────────────────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  say "Installing Docker (from Docker's own repository)…"
  command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null; }
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker info >/dev/null 2>&1 || die "Docker is installed but not running. Check: systemctl status docker"

# ── Licence ─────────────────────────────────────────────────────────────────────────────────────
# A licence key (patch_…) downloads from HQ's image store and keeps the install's licence; an access
# code (ghp_…) is the older way, from GitHub's registry, kept for installs made before licences.
echo
if [ -z "${PATCH_LICENCE_KEY:-}" ] && [ -z "${PATCH_ACCESS_CODE:-}" ]; then
  say "patch is private. You need the licence key you were given (it starts patch_)."
  ask KEY_IN "Licence key" "" secret
  case "$KEY_IN" in ghp_*) PATCH_ACCESS_CODE=$KEY_IN ;; *) PATCH_LICENCE_KEY=$KEY_IN ;; esac
fi
PATCH_LICENCE_KEY=${PATCH_LICENCE_KEY:-}; PATCH_ACCESS_CODE=${PATCH_ACCESS_CODE:-}; IMAGES=''
if [ -n "$PATCH_LICENCE_KEY" ]; then
  case "$PATCH_LICENCE_KEY" in patch_*) ;; *) die "That does not look like a licence key (they start patch_)." ;; esac
  PATCH_HQ_URL=${PATCH_HQ_URL:-$BUILT_IN_HQ}
  ask PATCH_HQ_URL "HQ's address, as given with the key (e.g. hq.example.co.uk)"
  PATCH_HQ_URL=$(hq_url "$PATCH_HQ_URL") || die "That is not an address like hq.example.co.uk."
  # Asked as a check only: HQ says whose licence it is, its state and where to download from, and
  # records nothing. The key goes in a header from a file descriptor, never on a command line.
  answer=$(curl -sS -m 20 -X POST -H "@"<(printf 'Authorization: Bearer %s\n' "$PATCH_LICENCE_KEY") -H 'Content-Type: application/json' \
    --data '{"check":true}' -w '\n%{http_code}' "$PATCH_HQ_URL/api/hq/m/checkin" 2>/dev/null || true)
  code=$(printf '%s' "$answer" | tail -1); body=$(printf '%s' "$answer" | sed '$d')
  [ "$code" = 401 ] && die "HQ does not know that licence key. Check it was copied whole."
  [ "$code" = 200 ] || die "Could not reach HQ at $PATCH_HQ_URL (answered ${code:-nothing}). Check the address."
  status=$(printf '%s' "$body" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')
  company=$(printf '%s' "$body" | sed -n 's/.*"company":"\([^"]*\)".*/\1/p')
  IMAGES=$(printf '%s' "$body" | sed -n 's/.*"images":"\([a-z0-9.:-]*\)".*/\1/p')
  [ "$status" = valid ] || die "That licence ($company) has $([ "$status" = revoked ] && echo 'been withdrawn' || echo 'ended'), so patch cannot be downloaded with it."
  [ -n "$IMAGES" ] || die "HQ has no images address set up yet, so there is nowhere to download from. Ask whoever runs HQ."
  printf '%s' "$PATCH_LICENCE_KEY" | docker login "$IMAGES" -u licence --password-stdin >/dev/null 2>&1 \
    || die "HQ's image store at $IMAGES did not accept the key."
  say "✓ Licensed to $company"
else
  [ -n "$PATCH_ACCESS_CODE" ] || die "A licence key is needed to download patch."
  printf '%s' "$PATCH_ACCESS_CODE" | docker login ghcr.io -u "$REGISTRY_USER" --password-stdin >/dev/null 2>&1 \
    || die "That access code was not accepted. Check it was copied whole, or ask for a new one."
  say "✓ Access code accepted"
fi

# ── How it will be reached ──────────────────────────────────────────────────────────────────────
mkdir -p "$DIR"
cd "$DIR"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -f .env ]; then
  say "Keeping the existing settings in $DIR/.env"
  # …except what was just given. With a licence, this is also how an install made with an access
  # code moves to HQ's image store: run the installer again and give it the licence key.
  if [ -n "$PATCH_LICENCE_KEY" ]; then
    # Moving to HQ downloads HQ's newest release, which may be newer than what runs here: back up first.
    if [ -f docker-compose.yml ] && docker compose ps -q backup 2>/dev/null | grep -q .; then
      say "Backing up before moving to HQ's images…"
      docker compose exec -T backup sh /app/scripts/backup.sh now >/dev/null || die "The backup did not complete, so nothing was changed."
    fi
    setenv PATCH_LICENCE_KEY "$PATCH_LICENCE_KEY"; setenv PATCH_HQ_URL "$PATCH_HQ_URL"
    setenv PATCH_IMAGE "$IMAGES/patch"; setenv PATCH_UPDATER_IMAGE "$IMAGES/patch-updater"
  else
    setenv PATCH_ACCESS_CODE "$PATCH_ACCESS_CODE"
  fi
else
  # Remote access is set up in the browser now (Settings → Remote access); a tunnel given here, by
  # the Proxmox script or by hand, is still used.
  PATCH_TUNNEL=${PATCH_TUNNEL:-}
  TUNNEL_TOKEN=$( [ -n "$PATCH_TUNNEL" ] && token_from "$PATCH_TUNNEL" || true )
  if [ -n "$TUNNEL_TOKEN" ]; then
    case "$TUNNEL_TOKEN" in eyJ*) ;; *) die "That does not look like a tunnel token (they start eyJ)." ;; esac
    ask PATCH_URL "The address you will give it in Cloudflare, e.g. kit.yourdomain.co.uk"
    PATCH_URL="https://${PATCH_URL#https://}"; PATCH_URL=${PATCH_URL%/}
  else
    PATCH_URL=${PATCH_URL:-http://$IP:$PORT}
  fi
  umask 077
  cat > .env <<EOF
# patch settings for this install. Keep a copy somewhere safe (a password manager).
# Change with the patchctl command (patchctl help) or edit here and run: patchctl restart
POSTGRES_PASSWORD=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
PATCH_ACCESS_CODE=$PATCH_ACCESS_CODE
PATCH_LICENCE_KEY=$PATCH_LICENCE_KEY
PATCH_HQ_URL=${PATCH_HQ_URL:-}
$([ -n "$IMAGES" ] && printf 'PATCH_IMAGE=%s/patch\nPATCH_UPDATER_IMAGE=%s/patch-updater' "$IMAGES" "$IMAGES")
PUBLIC_BASE_URL=$PATCH_URL
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
curl -fsSL "$SOURCE/patchctl" -o /usr/local/bin/patchctl && chmod +x /usr/local/bin/patchctl
# `pct enter` can start a shell without /usr/local/bin on its PATH; /usr/bin is always there.
ln -sf /usr/local/bin/patchctl /usr/bin/patchctl
# Backups hold the database and the app's own secrets: root only.
mkdir -p backups && chmod 0700 backups
PORT=$(grep '^APP_PORT=' .env | cut -d= -f2- || true); PORT=${PORT:-3000}
echo
say "Downloading patch (a minute or two the first time)…"
docker compose pull -q
docker compose up -d --remove-orphans

say "Starting…"
for _ in $(seq 1 60); do
  if curl -fsS -m 3 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    URL=$(grep '^PUBLIC_BASE_URL=' .env | cut -d= -f2-)
    echo
    bold "✓ patch. is running"
    say "Open it to finish setting up:  http://$IP:$PORT"
    [ "${URL#https://}" != "$URL" ] && say "From anywhere:    $URL   (once the hostname is added in Cloudflare)"
    # A QR code, for opening it on a phone or tablet without typing the address.
    command -v qrencode >/dev/null && { echo; qrencode -t ansiutf8 -m 2 "http://$IP:$PORT" | sed 's/^/  /'; }
    say "Later jobs: patchctl update | backup | tunnel | logs | status   (patchctl help)"
    exit 0
  fi
  sleep 3
done
die "patch did not answer within three minutes. See: patchctl logs"
