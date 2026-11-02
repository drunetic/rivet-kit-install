#!/usr/bin/env bash
# ── patch HQ installer, run inside its own Debian container or VM ───────────────────────────
#
#   On Proxmox (makes the container, then runs this inside it):
#     PATCH_ROLE=hq bash -c "$(curl -fsSL https://raw.githubusercontent.com/drunetic/rivet-kit-install/main/proxmox.sh)"
#   On any other Debian or Ubuntu machine:
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/drunetic/rivet-kit-install/main/hq-install.sh)"
#
# HQ builds patch from its private code, so it asks for a read-only GitHub token, fetches the code
# with it, and builds the first images here (nothing has been released yet for it to download).
# Then it writes /opt/patch/{docker-compose.yml,registry.yml,.env}, starts everything, and logs this
# box's Docker in to its own image store. See docs/hq.md in the code for what each part does.
#
# Non-interactive (the Proxmox script uses this): set GITHUB_TOKEN, and optionally PATCH_TUNNEL,
# PATCH_URL (HQ's address) and PATCH_IMAGES_URL (the images address), PATCH_PORT, PATCH_DIR.
set -euo pipefail

DIR=${PATCH_DIR:-/opt/patch}
PORT=${PATCH_PORT:-3000}
REPO=${PATCH_REPO:-https://github.com/drunetic/Rivet-Kit.git}
BRANCH=${PATCH_BRANCH:-main}
STORE=127.0.0.1:8080

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
token_from() { printf '%s' "$1" | sed 's/.*--token[[:space:]]*//' | tr -d '[:space:]'; }
secret() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
# The token rides in a header for each git call, set through the environment so it is never on a
# command line (where ps would show it), in the URL or in .git/config.
git_() {
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')" git "$@"
}

[ "$(id -u)" = 0 ] || die "Run this as root (on Debian: su - first)."
bold "patch HQ installer"

# ── Docker and git ──────────────────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  say "Installing Docker (from Docker's own repository)…"
  command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null; }
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
command -v git >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git jq >/dev/null; }
command -v jq >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq >/dev/null
systemctl enable --now docker >/dev/null 2>&1 || true
docker info >/dev/null 2>&1 || die "Docker is installed but not running. Check: systemctl status docker"

# ── The code ────────────────────────────────────────────────────────────────────────────────────
echo
say "HQ builds patch from its code on GitHub, so it needs a token that can read it, and nothing more:"
say "GitHub → Settings → Developer settings → Fine-grained tokens → Generate new token;"
say "Repository access: only drunetic/Rivet-Kit; Permissions: Contents, Read-only."
ask GITHUB_TOKEN "GitHub token" "" secret
[ -n "$GITHUB_TOKEN" ] || die "A token is needed to fetch the code."
git_ ls-remote --exit-code "$REPO" "refs/heads/$BRANCH" >/dev/null 2>&1 \
  || die "GitHub did not let that token read $REPO. Check it is for that repository with Contents: Read-only."
say "✓ The token can read the code"

mkdir -p "$DIR"; cd "$DIR"
SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT
say "Fetching the code…"
git_ clone -q --depth 1 --branch "$BRANCH" "$REPO" "$SRC"
VERSION=$(jq -r .version "$SRC/package.json")
[ -f "$SRC/hq/docker-compose.yml" ] || die "This version of the code ($VERSION) has no HQ files."

# ── Settings ────────────────────────────────────────────────────────────────────────────────────
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -f .env ]; then
  say "Keeping the existing settings in $DIR/.env"
  setenv GITHUB_TOKEN "$GITHUB_TOKEN"
else
  if [ -z "${PATCH_TUNNEL+x}" ]; then
    echo
    say "Installs and customers reach HQ through a Cloudflare Tunnel, on two addresses:"
    say "  hq.<your domain>      the admin pages and (later) licences"
    say "  images.<your domain>  where installs download updates"
    say "You can skip this now and add it later with: patchctl tunnel"
    say "In Cloudflare: Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared → Docker."
    ask PATCH_TUNNEL "Paste Cloudflare's 'docker run …' command (or press Enter to skip)"
  fi
  TUNNEL_TOKEN=$( [ -n "$PATCH_TUNNEL" ] && token_from "$PATCH_TUNNEL" || true )
  if [ -n "$TUNNEL_TOKEN" ]; then
    case "$TUNNEL_TOKEN" in eyJ*) ;; *) die "That does not look like a tunnel token (they start eyJ)." ;; esac
    ask PATCH_URL "HQ's address, e.g. hq.yourdomain.co.uk"
    ask PATCH_IMAGES_URL "The images address, e.g. images.yourdomain.co.uk"
    PATCH_URL="https://${PATCH_URL#https://}"; PATCH_URL=${PATCH_URL%/}
    PATCH_IMAGES_URL=${PATCH_IMAGES_URL#https://}; PATCH_IMAGES_URL=${PATCH_IMAGES_URL%/}
  else
    PATCH_URL=${PATCH_URL:-http://$IP:$PORT}; PATCH_IMAGES_URL=${PATCH_IMAGES_URL:-}
  fi
  umask 077
  cat > .env <<ENV
# patch HQ settings. Keep a copy somewhere safe (a password manager), with the signing keys.
# Change with patchctl (patchctl help), or edit here and run: patchctl restart
POSTGRES_PASSWORD=$(secret)
HQ_BUILDER_SECRET=$(secret)
GITHUB_TOKEN=$GITHUB_TOKEN
PUBLIC_BASE_URL=$PATCH_URL
HQ_IMAGES_ADDRESS=$PATCH_IMAGES_URL
APP_PORT=$PORT
TZ=${TZ:-Europe/London}
TRUST_CLOUDFLARE_HEADERS=$([ -n "$TUNNEL_TOKEN" ] && echo 1 || echo 0)
COMPOSE_PROFILES=$([ -n "$TUNNEL_TOKEN" ] && echo tunnel || true)
TUNNEL_TOKEN=$TUNNEL_TOKEN
ENV
  umask 022
fi

# ── First images, built here ────────────────────────────────────────────────────────────────────
# Tagged with the store's name, so compose finds them already on this box; once something is
# released, Settings → Updates pulls newer ones from the store like any install. Only on a new HQ:
# run again, this must not put unreleased code from GitHub on HQ behind Release's back.
if docker image inspect "$STORE/patch:latest" >/dev/null 2>&1 && docker image inspect "$STORE/patch-updater:latest" >/dev/null 2>&1; then
  say "Images already on this box; not building again (HQ updates through Releases and Settings → Updates)."
else
say "Building patch $VERSION (ten minutes or so the first time)…"
NOTES=$(awk '/^## /{n++} n==1' "$SRC/CHANGELOG.md" | base64 | tr -d '\n')
docker build -q --build-arg "VERSION=$VERSION" --label "org.opencontainers.image.version=$VERSION" --label "patch.notes=$NOTES" \
  -t "$STORE/patch:$VERSION" -t "$STORE/patch:latest" "$SRC" >/dev/null || die "Building patch failed. Run again to retry; the output above says why."
docker build -q -f "$SRC/Dockerfile.updater" --label "org.opencontainers.image.version=$VERSION" \
  -t "$STORE/patch-updater:$VERSION" -t "$STORE/patch-updater:latest" "$SRC" >/dev/null || die "Building the updater failed."
fi

cp "$SRC/hq/docker-compose.yml" docker-compose.yml
cp "$SRC/hq/registry.yml" registry.yml
cp "$SRC/install/patchctl" /usr/local/bin/patchctl && chmod +x /usr/local/bin/patchctl
# `pct enter` can start a shell without /usr/local/bin on its PATH; /usr/bin is always there.
ln -sf /usr/local/bin/patchctl /usr/bin/patchctl
# Backups hold the database and the signing keys: root only.
mkdir -p backups && chmod 0700 backups
# Once a month, at a quiet hour, free the space old builds took (patchctl clean).
if [ -d /etc/cron.d ]; then
  printf '# patch HQ: sweep the image store monthly (patchctl clean)\n17 4 1 * * root /usr/local/bin/patchctl clean >> /var/log/patch-clean.log 2>&1\n' > /etc/cron.d/patch-hq-clean
fi

say "Starting…"
docker compose up -d --remove-orphans
for i in $(seq 1 60); do
  curl -fsS -m 3 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
  [ "$i" = 60 ] && die "HQ did not answer within three minutes. See: patchctl logs"
  sleep 3
done
# The store reads HQ's key when it starts; on a new HQ it started before the key existed.
docker compose restart registry >/dev/null
BUILDER=$(grep '^HQ_BUILDER_SECRET=' .env | cut -d= -f2-)
for i in $(seq 1 30); do
  printf '%s' "$BUILDER" | docker login "$STORE" -u builder --password-stdin >/dev/null 2>&1 && break
  [ "$i" = 30 ] && die "Could not log this box in to its image store. See: patchctl logs registry"
  sleep 2
done

URL=$(grep '^PUBLIC_BASE_URL=' .env | cut -d= -f2-)
IMAGES=$(grep '^HQ_IMAGES_ADDRESS=' .env | cut -d= -f2-)
echo
bold "✓ patch HQ $VERSION is running"
say "On this network:  http://$IP:$PORT"
if [ "${URL#https://}" != "$URL" ]; then
  say "In Cloudflare, give the tunnel two public hostnames:"
  say "  ${URL#https://}  →  HTTP  app:3000"
  [ -n "$IMAGES" ] && say "  $IMAGES  →  HTTP  front:8080"
fi
say "Next:"
say "  1. Open it; the setup page makes your account."
say "  2. Releases shows the builder's first build within a few minutes."
say "  3. On Releases, download a copy of the signing keys and keep it off this box."
say "Later jobs: patchctl status | logs builder | backup   (patchctl help)"
