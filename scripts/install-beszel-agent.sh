#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Install the Beszel agent on a Linux VPS host as a systemd service.

Required:
  --hub-url URL      Public Beszel hub URL, e.g. https://beszel.tools.example.dev
  --token TOKEN      Universal token from Beszel Settings -> Tokens
  --key KEY          Public key shown when adding a system in Beszel

Optional:
  --listen ADDR      Listen address/port for the agent. Default: 45876
  --extra-fs LIST    Comma-separated extra filesystem names for monitoring
  --version VER      Beszel agent version. Default: latest
  --help             Show this help text

Example:
  sudo ./scripts/install-beszel-agent.sh \
    --hub-url https://beszel.tools.nitishsrivastava.dev \
    --token 'your-universal-token' \
    --key 'ssh-ed25519 AAAAC3...'
EOF
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "This script must run as root. Re-run with sudo." >&2
    exit 1
  fi
}

require_cmd() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

detect_arch() {
  local machine
  machine=$(uname -m)
  case "$machine" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv6l) echo "arm" ;;
    *)
      echo "Unsupported architecture: $machine" >&2
      exit 1
      ;;
  esac
}

HUB_URL=""
TOKEN=""
KEY=""
LISTEN="45876"
EXTRA_FS=""
VERSION="latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub-url)
      HUB_URL=${2:-}
      shift 2
      ;;
    --token)
      TOKEN=${2:-}
      shift 2
      ;;
    --key)
      KEY=${2:-}
      shift 2
      ;;
    --listen)
      LISTEN=${2:-}
      shift 2
      ;;
    --extra-fs)
      EXTRA_FS=${2:-}
      shift 2
      ;;
    --version)
      VERSION=${2:-}
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$HUB_URL" || -z "$TOKEN" || -z "$KEY" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 1
fi

require_root
require_cmd curl
require_cmd tar
require_cmd systemctl

ARCH=$(detect_arch)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_URL="https://github.com/henrygd/beszel/releases/${VERSION}/download/beszel-agent_Linux_${ARCH}.tar.gz"
if [[ "$VERSION" == "latest" ]]; then
  BIN_URL="https://github.com/henrygd/beszel/releases/latest/download/beszel-agent_Linux_${ARCH}.tar.gz"
fi

echo "Installing Beszel agent from: $BIN_URL"

mkdir -p /usr/local/bin /etc/beszel /var/lib/beszel-agent

if ! id beszel >/dev/null 2>&1; then
  useradd --system --home /var/lib/beszel-agent --shell /usr/sbin/nologin beszel
fi

curl -fsSL "$BIN_URL" | tar -xz -C "$TMP_DIR" beszel-agent
install -m 0755 "$TMP_DIR/beszel-agent" /usr/local/bin/beszel-agent

cat > /etc/beszel/beszel-agent.env <<EOF
LISTEN="$LISTEN"
KEY="$KEY"
TOKEN="$TOKEN"
HUB_URL="$HUB_URL"
EOF

if [[ -n "$EXTRA_FS" ]]; then
  printf 'EXTRA_FILESYSTEMS="%s"\n' "$EXTRA_FS" >> /etc/beszel/beszel-agent.env
fi

chown -R beszel:beszel /etc/beszel /var/lib/beszel-agent
chmod 0600 /etc/beszel/beszel-agent.env

cat > /etc/systemd/system/beszel-agent.service <<'EOF'
[Unit]
Description=Beszel Agent
After=network-online.target
Wants=network-online.target

[Service]
User=beszel
Group=beszel
EnvironmentFile=/etc/beszel/beszel-agent.env
ExecStart=/usr/local/bin/beszel-agent
Restart=on-failure
RestartSec=5
WorkingDirectory=/var/lib/beszel-agent
StateDirectory=beszel-agent

KeyringMode=private
LockPersonality=yes
NoNewPrivileges=yes
ProtectClock=yes
ProtectHome=read-only
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectSystem=strict
RemoveIPC=yes
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now beszel-agent.service

echo
echo "Beszel agent installed and started."
echo "Check status with: systemctl status beszel-agent"
echo "View logs with: journalctl -u beszel-agent -f"
