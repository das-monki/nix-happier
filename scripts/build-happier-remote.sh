#!/usr/bin/env bash
# Build happier packages on a temporary big aarch64 box (Hetzner or AWS
# Graviton), then copy the results into the local Nix store. Modeled on slicer's
# build-bambu-remote.sh.
#
# Why this exists: the happier monorepo build (especially happier-ui-web, which
# yarn-installs the full Expo/RN app) needs far more transient disk than small
# targets like dev-01 (37G) or the macOS linux-builder VM (20G) have. Building
# it there fails with ENOSPC. Evaluation happens locally; only realisation runs
# on the remote box (--store ssh-ng + --eval-store auto), so the box needs no
# access to private flake inputs.
#
# Usage:
#   ./scripts/build-happier-remote.sh [--provider hetzner|aws] [packages...] [--to <ssh-uri>]
#
#   # Hetzner (default), build happier-server, copy to local store:
#   ./scripts/build-happier-remote.sh
#
#   # AWS Graviton (use when Hetzner ARM is out of stock):
#   ./scripts/build-happier-remote.sh --provider aws
#
#   # Build several packages:
#   ./scripts/build-happier-remote.sh happier-server happier-cli
#
#   # Also push the results to a host's store (e.g. to prime dev-01 directly):
#   ./scripts/build-happier-remote.sh --to ssh://root@dev-01.tail47f1b.ts.net
#
# Common env overrides:
#   BUILD_CORES   Cores passed to nix build (default: 8).
#   SSH_KEY       Local private key (default: ~/.ssh/id_ed25519).
#
# Hetzner overrides:
#   HCLOUD_TOKEN  Hetzner API token (or a configured `hcloud context`).
#   SERVER_TYPE   Server type (default: cax31 — 8 vCPU / 16G / 160G; cax41 is
#                 often out of stock, and the build is disk-bound, so 160G is
#                 plenty).
#   LOCATION      Location (default: fsn1; try nbg1/hel1 if out of stock).
#   SSH_KEY_NAME  Name of the public key registered in Hetzner (default: sion@tailscale).
#
# AWS overrides (aws CLI must be configured):
#   INSTANCE_TYPE Instance type (default: c7g.2xlarge — 8 vCPU / 16G).
#   REGION        Region (default: eu-north-1).
#   DISK_GB       Root EBS size in GB (default: 80).
#
# A repo-root .env (gitignored) is sourced if present, so you can keep
# HCLOUD_TOKEN / AWS creds there instead of exporting them.
#
# On success the build box is destroyed. On failure it is kept alive so you can
# re-run (the script reuses an existing "build-happier" box).

set -euo pipefail

START_TIME=$SECONDS
elapsed() { printf '%dm%ds' $(((SECONDS - START_TIME) / 60)) $(((SECONDS - START_TIME) % 60)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load local secrets (HCLOUD_TOKEN, AWS creds, etc.) if present.
if [ -f "$REPO_DIR/.env" ]; then
  # shellcheck disable=SC1091
  set -a && . "$REPO_DIR/.env" && set +a
fi

SERVER_NAME="build-happier"
PROVIDER="hetzner"
BUILD_SYSTEM="aarch64-linux"
BUILD_CORES="${BUILD_CORES:-8}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR"

# Hetzner defaults
SERVER_TYPE="${SERVER_TYPE:-cax31}"
LOCATION="${LOCATION:-fsn1}"
SSH_KEY_NAME="${SSH_KEY_NAME:-sion@tailscale}"

# AWS defaults
INSTANCE_TYPE="${INSTANCE_TYPE:-c7g.2xlarge}"
REGION="${REGION:-eu-north-1}"
DISK_GB="${DISK_GB:-80}"

# --- Parse args: --provider <p>, --to <uri>, bare names are package attrs ----
PACKAGES=()
COPY_TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider)
      PROVIDER="$2"
      shift 2
      ;;
    --provider=*)
      PROVIDER="${1#--provider=}"
      shift
      ;;
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

# ============================================================================
# Hetzner provider
# ============================================================================

hetzner_create() {
  if ! command -v hcloud >/dev/null 2>&1; then
    echo "Error: hcloud not found. Enter the dev shell (nix develop) or install it." >&2
    exit 1
  fi
  if ! hcloud server list >/dev/null 2>&1; then
    echo "Error: hcloud not configured. Set HCLOUD_TOKEN (e.g. in $REPO_DIR/.env) or run 'hcloud context create'." >&2
    exit 1
  fi

  local existing_ip
  existing_ip=$(hcloud server describe "$SERVER_NAME" -o json 2>/dev/null | jq -r '.public_net.ipv4.ip // empty' || true)
  if [ -n "$existing_ip" ]; then
    echo "==> Reusing existing build server ($SERVER_NAME) at $existing_ip"
    SERVER_IP="$existing_ip"
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
  SSH_USER="root"
}

hetzner_destroy() {
  hcloud server delete "$SERVER_NAME" >/dev/null 2>&1 || true
}

# ============================================================================
# AWS provider (Graviton)
# ============================================================================

aws_create() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "Error: aws CLI not found. Enter the dev shell (nix develop) or install it." >&2
    exit 1
  fi
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "Error: AWS CLI not configured. Run 'aws configure' (or set AWS creds in $REPO_DIR/.env)." >&2
    exit 1
  fi
  export AWS_DEFAULT_REGION="$REGION"

  # Reuse a previously-tagged instance if it's still running.
  local existing_id
  existing_id=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$SERVER_NAME" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)
  if [ -n "$existing_id" ] && [ "$existing_id" != "None" ]; then
    AWS_INSTANCE_ID="$existing_id"
    SERVER_IP=$(aws ec2 describe-instances --instance-ids "$existing_id" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    echo "==> Reusing existing instance $existing_id at $SERVER_IP"
    REUSED_SERVER=true
    SSH_USER="ubuntu"
    return
  fi

  local ami_id
  ami_id=$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" \
      "Name=architecture,Values=arm64" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
  if [ -z "$ami_id" ] || [ "$ami_id" = "None" ]; then
    echo "Error: could not find Ubuntu 24.04 ARM AMI in $REGION" >&2
    exit 1
  fi

  local sg_id
  sg_id=$(aws ec2 describe-security-groups --group-names "nix-build-ssh" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
  if [ -z "$sg_id" ] || [ "$sg_id" = "None" ]; then
    sg_id=$(aws ec2 create-security-group --group-name "nix-build-ssh" \
      --description "SSH access for Nix remote builds" --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress \
      --group-id "$sg_id" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
  fi

  if ! aws ec2 describe-key-pairs --key-names "$(basename "$SSH_KEY")" >/dev/null 2>&1; then
    echo "==> Importing SSH key to AWS..."
    aws ec2 import-key-pair --key-name "$(basename "$SSH_KEY")" \
      --public-key-material "fileb://${SSH_KEY}.pub" >/dev/null
  fi
  local key_name
  key_name="$(basename "$SSH_KEY")"

  local bdm
  bdm="[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${DISK_GB},\"VolumeType\":\"gp3\"}}]"

  echo "==> Creating $INSTANCE_TYPE spot instance in $REGION (AMI: $ami_id, ${DISK_GB}G)..."
  AWS_INSTANCE_ID=$(aws ec2 run-instances \
    --instance-type "$INSTANCE_TYPE" --image-id "$ami_id" --key-name "$key_name" \
    --security-group-ids "$sg_id" \
    --instance-market-options '{"MarketType":"spot"}' \
    --block-device-mappings "$bdm" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$SERVER_NAME}]" \
    --query 'Instances[0].InstanceId' --output text 2>/dev/null) || true

  if [ -z "${AWS_INSTANCE_ID:-}" ] || [ "$AWS_INSTANCE_ID" = "None" ]; then
    echo "    Spot unavailable, using on-demand..."
    AWS_INSTANCE_ID=$(aws ec2 run-instances \
      --instance-type "$INSTANCE_TYPE" --image-id "$ami_id" --key-name "$key_name" \
      --security-group-ids "$sg_id" \
      --block-device-mappings "$bdm" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$SERVER_NAME}]" \
      --query 'Instances[0].InstanceId' --output text)
  fi

  echo "    Instance: $AWS_INSTANCE_ID"
  echo "==> Waiting for instance to be running..."
  aws ec2 wait instance-running --instance-ids "$AWS_INSTANCE_ID"
  SERVER_IP=$(aws ec2 describe-instances --instance-ids "$AWS_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  echo "    IP: $SERVER_IP"
  REUSED_SERVER=false
  SSH_USER="ubuntu"
}

aws_destroy() {
  if [ -n "${AWS_INSTANCE_ID:-}" ]; then
    aws ec2 terminate-instances --instance-ids "$AWS_INSTANCE_ID" >/dev/null 2>&1 || true
  fi
}

# ============================================================================
# Provision
# ============================================================================

case "$PROVIDER" in
  hetzner)
    hetzner_create
    DESTROY_CMD="hetzner_destroy"
    ;;
  aws)
    aws_create
    DESTROY_CMD="aws_destroy"
    ;;
  *)
    echo "Unknown provider: $PROVIDER (use 'hetzner' or 'aws')" >&2
    exit 1
    ;;
esac

SSH="ssh $SSH_OPTS -i $SSH_KEY ${SSH_USER}@${SERVER_IP}"

echo "==> Waiting for SSH..."
until $SSH true 2>/dev/null; do sleep 2; done

# ============================================================================
# Set up Nix on the box (single-user, flakes enabled) + swap
# ============================================================================

if [ "$REUSED_SERVER" = false ]; then
  echo "==> Installing Nix (single-user, flakes enabled)..."
  if [ "$SSH_USER" = "ubuntu" ]; then
    # AWS Ubuntu: install as root via sudo, then enable root SSH for ssh-ng.
    $SSH 'sudo mkdir -p /etc/nix && printf "build-users-group =\nexperimental-features = nix-command flakes\n" | sudo tee /etc/nix/nix.conf >/dev/null'
    $SSH 'curl -sSfL https://nixos.org/nix/install -o /tmp/nix-install.sh && sudo sh /tmp/nix-install.sh --no-daemon 2>&1 | tail -3'
    $SSH 'sudo ln -sf /nix/var/nix/profiles/default/bin/* /usr/local/bin/'
    $SSH 'sudo mkdir -p /root/.ssh && sudo cp ~/.ssh/authorized_keys /root/.ssh/authorized_keys'
    echo "==> Adding swap (safety net)..."
    $SSH 'sudo fallocate -l 16G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile' || true
  else
    # Hetzner: already root.
    $SSH 'mkdir -p /etc/nix && printf "build-users-group =\nexperimental-features = nix-command flakes\n" > /etc/nix/nix.conf'
    $SSH 'sh <(curl -sSfL https://nixos.org/nix/install) --no-daemon 2>&1 | tail -3'
    $SSH 'ln -sf /root/.nix-profile/bin/* /usr/local/bin/ 2>/dev/null || true'
    echo "==> Adding swap (safety net)..."
    $SSH 'fallocate -l 16G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile' || true
  fi
else
  echo "==> Skipping setup (box already provisioned)"
fi

# ssh-ng always connects as the store owner (root).
REMOTE_STORE="ssh-ng://root@${SERVER_IP}"
export NIX_SSHOPTS="$SSH_OPTS -i $SSH_KEY"

# ============================================================================
# Build remotely (eval local, realise on the box)
# ============================================================================

echo "==> Building on remote ($BUILD_SYSTEM, $BUILD_CORES cores): ${PACKAGES[*]}"
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
  echo "==> Remote build failed. Box kept alive at $SERVER_IP for reuse." >&2
  echo "    Re-run this script to retry, or destroy with:" >&2
  if [ "$PROVIDER" = "hetzner" ]; then
    echo "      hcloud server delete $SERVER_NAME" >&2
  else
    echo "      aws ec2 terminate-instances --instance-ids ${AWS_INSTANCE_ID:-unknown}" >&2
  fi
  exit "${BUILD_RC:-1}"
fi
printf '    Built: %s\n' "${STORE_PATHS[@]}"

# ============================================================================
# Copy results back
# ============================================================================

echo "==> Copying results to local store..."
nix copy --no-check-sigs --from "$REMOTE_STORE" "${STORE_PATHS[@]}"

if [ -n "$COPY_TO" ]; then
  echo "==> Copying results to $COPY_TO..."
  nix copy --no-check-sigs --from "$REMOTE_STORE" --to "$COPY_TO" "${STORE_PATHS[@]}"
fi

echo "==> Build succeeded, destroying box..."
"$DESTROY_CMD"

echo ""
echo "==> Done in $(elapsed)! Paths are in your local store:"
printf '    %s\n' "${STORE_PATHS[@]}"
echo ""
echo "Now deploy as usual (the closure is already realised locally, so dev-01"
echo "won't rebuild it):"
echo "    cd ../infra && deploy .#dev-01"
