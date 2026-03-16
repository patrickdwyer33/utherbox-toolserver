#!/usr/bin/env bash
# utherbox-toolserver/setup.sh
# Runs as root via cloud-init on each new project VM, AFTER setup-privileged.sh.
# Scope: download and install MCP binaries from S3.
#
# Prerequisites (handled by cloud-init's setup-privileged.sh, which runs first):
#   - toolserver and claude users created
#   - /home/toolserver/.credentials.json installed (600, toolserver:toolserver)
#   - /var/lib/utherbox/certs/ created (755, toolserver:toolserver)
#   - SSH hardened, claude sudoers removed
set -euo pipefail

# credentials.json is pre-installed by setup-privileged.sh; root can read it.
CREDS_FILE="/home/toolserver/.credentials.json"

# ---------------------------------------------------------------------------
# 1. Parse S3 credentials for binary download
# ---------------------------------------------------------------------------
S3_ENDPOINT=$(jq -r '.s3_endpoint' "$CREDS_FILE")
S3_BUCKET=$(jq -r '.s3_bucket_binaries // "utherbox-binaries"' "$CREDS_FILE")
S3_ACCESS=$(jq -r '.s3_access_key' "$CREDS_FILE")
S3_SECRET=$(jq -r '.s3_secret_key' "$CREDS_FILE")

if [[ "$S3_ENDPOINT" == "null" || -z "$S3_ENDPOINT" || \
      "$S3_ACCESS" == "null"   || -z "$S3_ACCESS"   || \
      "$S3_SECRET" == "null"   || -z "$S3_SECRET" ]]; then
  echo "ERROR: credentials.json is missing required S3 fields" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Fetch latest binary versions
# ---------------------------------------------------------------------------
LATEST=$(AWS_ACCESS_KEY_ID="$S3_ACCESS" AWS_SECRET_ACCESS_KEY="$S3_SECRET" \
  aws s3 cp "s3://${S3_BUCKET}/latest.json" - --endpoint-url "$S3_ENDPOINT")
VM_VER=$(echo "$LATEST" | jq -r '."vm-mcp"')
DNS_VER=$(echo "$LATEST" | jq -r '."dns-mcp"')

if [[ "$VM_VER" == "null" || -z "$VM_VER" || "$DNS_VER" == "null" || -z "$DNS_VER" ]]; then
  echo "ERROR: latest.json is missing vm-mcp or dns-mcp version" >&2
  exit 1
fi

echo "Installing vm-mcp@${VM_VER} dns-mcp@${DNS_VER}"

# ---------------------------------------------------------------------------
# 3. Download, verify checksum, and install each binary
# ---------------------------------------------------------------------------
# Binaries live in /home/toolserver/bin/ (toolserver-owned) so that the update
# script can atomically replace them with rename() while they are running.
# /usr/local/bin/{name} is a symlink into this directory.
mkdir -p /home/toolserver/bin
chown toolserver:toolserver /home/toolserver/bin
chmod 755 /home/toolserver/bin

download_and_install() {
  local name="$1"
  local version="$2"
  local dest="/home/toolserver/bin/${name}"
  local tmp="${dest}.tmp"

  echo "Downloading ${name}@${version}..."
  AWS_ACCESS_KEY_ID="$S3_ACCESS" AWS_SECRET_ACCESS_KEY="$S3_SECRET" \
    aws s3 cp "s3://${S3_BUCKET}/${name}/${version}/${name}" "$tmp" \
    --endpoint-url "$S3_ENDPOINT"

  local expected actual
  expected=$(AWS_ACCESS_KEY_ID="$S3_ACCESS" AWS_SECRET_ACCESS_KEY="$S3_SECRET" \
    aws s3 cp "s3://${S3_BUCKET}/${name}/${version}/${name}.sha256" - \
    --endpoint-url "$S3_ENDPOINT")
  actual=$(sha256sum "$tmp" | awk '{print $1}')

  if [[ "$expected" != "$actual" ]]; then
    echo "ERROR: checksum mismatch for ${name}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    rm -f "$tmp"
    exit 1
  fi

  mv "$tmp" "$dest"
  chown toolserver:toolserver "$dest"
  chmod 4755 "$dest"   # setuid: executes as toolserver when spawned by claude
  ln -sf "$dest" "/usr/local/bin/${name}"
  echo "${name} installed at ${dest} (setuid, symlinked from /usr/local/bin/${name})"
}

download_and_install vm-mcp  "$VM_VER"
download_and_install dns-mcp "$DNS_VER"

# ---------------------------------------------------------------------------
# 4. Install the update script
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -o toolserver -g toolserver -m 755 "$SCRIPT_DIR/update-mcp-binaries.sh" \
  /usr/local/bin/update-mcp-binaries

# ---------------------------------------------------------------------------
# 5. Systemd service + timer: run as toolserver on boot and daily
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/utherbox-update-mcp.service << 'EOF'
[Unit]
Description=Update Utherbox MCP binaries

[Service]
Type=oneshot
User=toolserver
ExecStart=/bin/bash /usr/local/bin/update-mcp-binaries
StandardOutput=journal
StandardError=journal
EOF

cat > /etc/systemd/system/utherbox-update-mcp.timer << 'EOF'
[Unit]
Description=Update Utherbox MCP binaries on boot and daily

[Timer]
OnBootSec=1min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now utherbox-update-mcp.timer

echo "utherbox-toolserver setup complete"
