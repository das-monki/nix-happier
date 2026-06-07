#!/usr/bin/env bash
# Build happier packages on a temporary big aarch64 Hetzner box, then copy the
# results into the local Nix store. Modeled on slicer's build-bambu-remote.sh.
#
# Why this exists: the happier monorepo build (especially happier-ui-web, which
# yarn-installs the full Expo/RN app) needs far more transient disk than small
# targets like dev-01 (37G) or the macOS linux-builder VM (20G) have. Building
# it there fails with ENOSPC. Evaluation happens locally; only realisation runs
# on the remote box (--store ssh-ng + --eval-store auto), so the box needs no
# access to private flake inputs.
#
# Usage:
#   ./scripts/build-happier-remote.sh [packages...] [--to <ssh-uri>]
#
#   # Build the default (happier-server) and copy to local store:
#   ./scripts/build-happier-remote.sh
#
#   # Build several packages:
#   ./scripts/build-happier-remote.sh happier-server happier-cli
#
#   # Also push the results to a host's store (e.g. to prime dev-01 directly):
#   ./scripts/build-happier-remote.sh --to ssh://root@dev-01.tail47f1b.ts.net
#
# Environment overrides:
#   HCLOUD_TOKEN      Hetzner API token (or a configured `hcloud context`).
#   SERVER_TYPE       Hetzner server type (default: cax31 — 8 vCPU / 16G / 160G;
#                     cax41 is often out of stock, and the build is disk-bound,
#                     not CPU-bound, so 160G is plenty).
#   LOCATION          Hetzner location (default: fsn1).
#   BUILD_CORES       Cores passed to nix build (default: 8, matching cax31).
#   SSH_KEY           Local private key (default: ~/.ssh/id_ed25519).
#   SSH_KEY_NAME      Name of the public key registered in Hetzner (default: sion@tailscale).
#
# A repo-root .env (gitignored) is sourced if present, so you can keep
# HCLOUD_TOKEN there instead of exporting it.
#
# On success the build server is destroyed. On failure it is kept alive so you
# can re-run (the script reuses an existing "build-happier" server).

set -euo pipefail

START_TIME=$SECONDS
elapsed() { printf '%dm%ds' $(((SECONDS - START_TIME) / 60)) $(((SECONDS - START_TIME) % 60)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load local secrets (HCLOUD_TOKEN etc.) if present.
if [ -f "$REPO_DIR/.env" ]; then
  # shellcheck disable=SC1091
  set -a && . "$REPO_DIR/.env" && set +a
fi

SERVER_NAME="build-happier"
SERVER_TYPE="${SERVER_TYPE:-cax31}"
LOCATION="${LOCATION:-fsn1}"
BUILD_CORES="${BUILD_CORES:-8}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_KEY_NAME="${SSH_KEY_NAME:-sion@tailscale}"
BUILD_SYSTEM="aarch64-linux"
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR"

# Parse args: bare names are package attrs; --to <uri> adds an extra copy target.
PACKAGES=()
COPY_TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to)
      COPY_TO="$2"
      shift 2
      ;;
    --to=*)
      COPY_TO="${1#--to=}"
      shift
      ;;
    *)
      PACKAGES+=("$1")
      shift
      ;;
  esac
done
if [ ${#PACKAGES[@]} -eq 0 ]; then
  PACKAGES=(happier-server)
fi

if ! command -v hcloud >/dev/null 2>&1; then
  echo "Error: hcloud not found. Enter the dev shell (nix develop) or install it." >&2
  exit 1
fi
if ! hcloud server list >/dev/null 2>&1; then
  echo "Error: hcloud not configured. Set HCLOUD_TOKEN (e.g. in $REPO_DIR/.env) or run 'hcloud context create'." >&2
  exit 1
fi

# --- Provision (reuse an existing build server if one is still around) --------
EXISTING_IP=$(hcloud server describe "$SERVER_NAME" -o json 2>/dev/null | jq -r '.public_net.ipv4.ip // empty' || true)
if [ -n "$EXISTING_IP" ]; then
  echo "==> Reusing existing build server ($SERVER_NAME) at $EXISTING_IP"
  SERVER_IP="$EXISTING_IP"
  REUSED_SERVER=true
else
  echo "==> Creating $SERVER_TYPE build server in $LOCATION..."
  SERVER_IP=$(hcloud server create \
    --name "$SERVER_NAME" \
    --type "$SERVER_TYPE" \
    --location "$LOCATION" \
    --image ubuntu-24.04 \
    --ssh-key "$SSH_KEY_NAME" \
    -o json | jq -r '.server.public_net.ipv4.ip')
  echo "    IP: $SERVER_IP"
  REUSED_SERVER=false
fi

SSH="ssh $SSH_OPTS -i $SSH_KEY root@${SERVER_IP}"

echo "==> Waiting for SSH..."
until $SSH true 2>/dev/null; do sleep 2; done

if [ "$REUSED_SERVER" = false ]; then
  echo "==> Installing Nix (single-user, flakes enabled)..."
  $SSH 'mkdir -p /etc/nix && printf "build-users-group =\nexperimental-features = nix-command flakes\n" > /etc/nix/nix.conf'
  $SSH 'sh <(curl -sSfL https://nixos.org/nix/install) --no-daemon 2>&1 | tail -3'
  $SSH 'ln -sf /root/.nix-profile/bin/* /usr/local/bin/ 2>/dev/null || true'

  echo "==> Adding swap (safety net)..."
  $SSH 'fallocate -l 16G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile' || true
else
  echo "==> Skipping setup (server already provisioned)"
fi

# --- Build remotely (eval local, realise on the box) -------------------------
echo "==> Building on remote ($BUILD_SYSTEM, $BUILD_CORES cores): ${PACKAGES[*]}"
export NIX_SSHOPTS="$SSH_OPTS -i $SSH_KEY"
REMOTE_STORE="ssh-ng://root@${SERVER_IP}"

INSTALLABLES=()
for pkg in "${PACKAGES[@]}"; do
  INSTALLABLES+=("${REPO_DIR}#packages.${BUILD_SYSTEM}.${pkg}")
done

set +e
mapfile -t STORE_PATHS < <(nix build \
  --print-out-paths \
  --no-link \
  -L \
  --store "$REMOTE_STORE" \
  --eval-store auto \
  --cores "$BUILD_CORES" \
  "${INSTALLABLES[@]}")
BUILD_RC=$?
set -e

if [ "$BUILD_RC" -ne 0 ] || [ ${#STORE_PATHS[@]} -eq 0 ]; then
  echo "" >&2
  echo "==> Remote build failed. Server kept alive at $SERVER_IP for reuse." >&2
  echo "    Re-run this script to retry, or destroy with: hcloud server delete $SERVER_NAME" >&2
  exit "${BUILD_RC:-1}"
fi
printf '    Built: %s\n' "${STORE_PATHS[@]}"

# --- Copy results back -------------------------------------------------------
echo "==> Copying results to local store..."
nix copy --no-check-sigs --from "$REMOTE_STORE" "${STORE_PATHS[@]}"

if [ -n "$COPY_TO" ]; then
  echo "==> Copying results to $COPY_TO..."
  nix copy --no-check-sigs --from "$REMOTE_STORE" --to "$COPY_TO" "${STORE_PATHS[@]}"
fi

echo "==> Build succeeded, destroying server..."
hcloud server delete "$SERVER_NAME" >/dev/null 2>&1 || true

echo ""
echo "==> Done in $(elapsed)! Paths are in your local store:"
printf '    %s\n' "${STORE_PATHS[@]}"
echo ""
echo "Now deploy as usual (the closure is already realised locally, so dev-01"
echo "won't rebuild it):"
echo "    cd ../infra && deploy .#dev-01"
