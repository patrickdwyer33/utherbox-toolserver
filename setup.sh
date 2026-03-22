#!/usr/bin/env bash
# utherbox-toolserver/setup.sh
# Runs as root via cloud-init on each new project VM, AFTER setup-privileged.sh.
# Scope: download and install MCP binaries via the platform API.
#
# Prerequisites (handled by cloud-init's setup-privileged.sh, which runs first):
#   - toolserver and claude users created
#   - /home/toolserver/.credentials.json installed (600, toolserver:toolserver)
#   - /var/lib/utherbox/certs/ created (755, toolserver:toolserver)
#   - SSH hardened, claude sudoers removed
set -euo pipefail
trap 'rm -f /var/lib/utherbox/bin/*.tmp 2>/dev/null || true' EXIT

# credentials.json is pre-installed by setup-privileged.sh; root can read it.
CREDS_FILE="/home/toolserver/.credentials.json"

# ---------------------------------------------------------------------------
# 1. Parse platform API credentials
# ---------------------------------------------------------------------------
PLATFORM_API_TOKEN=$(jq -r '.platform_api_token' "$CREDS_FILE")
PLATFORM_API_BASE=$(jq -r '.platform_api_base_url' "$CREDS_FILE")

if [[ "$PLATFORM_API_TOKEN" == "null" || -z "$PLATFORM_API_TOKEN" || \
      "$PLATFORM_API_BASE" == "null"  || -z "$PLATFORM_API_BASE" ]]; then
  echo "ERROR: credentials.json is missing platform_api_token or platform_api_base_url" >&2
  exit 1
fi

# Validate format before use
if [[ ! "$PLATFORM_API_TOKEN" =~ ^utbx_[0-9a-f]{64}$ ]]; then
  echo "ERROR: platform_api_token has unexpected format" >&2
  exit 1
fi
if [[ "$PLATFORM_API_BASE" != https://* ]]; then
  echo "ERROR: platform_api_base_url must begin with https://" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Fetch latest binary versions
# ---------------------------------------------------------------------------
LATEST=$(curl -sf --max-time 60 -H "Authorization: Bearer ${PLATFORM_API_TOKEN}" \
  "${PLATFORM_API_BASE}/binaries/latest.json")
VM_VER=$(echo "$LATEST" | jq -r '."vm-mcp"')
DNS_VER=$(echo "$LATEST" | jq -r '."dns-mcp"')
UPDATE_VER=$(echo "$LATEST" | jq -r '."update-mcp-binaries"')

if [[ "$VM_VER" == "null" || -z "$VM_VER" || \
      "$DNS_VER" == "null" || -z "$DNS_VER" || \
      "$UPDATE_VER" == "null" || -z "$UPDATE_VER" ]]; then
  echo "ERROR: latest.json is missing vm-mcp, dns-mcp, or update-mcp-binaries version" >&2
  exit 1
fi

echo "Installing vm-mcp@${VM_VER} dns-mcp@${DNS_VER} update-mcp-binaries@${UPDATE_VER}"

# ---------------------------------------------------------------------------
# 3. Download, verify checksum, and install each binary
# ---------------------------------------------------------------------------
# Binaries live in /var/lib/utherbox/bin/ (toolserver-owned) so that the update
# script can atomically replace them with rename() while they are running.
# /usr/local/bin/{name} is a symlink into this directory.
mkdir -p /var/lib/utherbox/bin
chown toolserver:toolserver /var/lib/utherbox/bin
chmod 755 /var/lib/utherbox/bin

download_and_install() {
  local name="$1"
  local version="$2"

  if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: unexpected version format for ${name}: ${version}" >&2
    exit 1
  fi

  local dest="/var/lib/utherbox/bin/${name}"
  local tmp="${dest}.tmp"

  echo "Downloading ${name}@${version}..."
  curl -sf --max-time 60 -H "Authorization: Bearer ${PLATFORM_API_TOKEN}" \
    "${PLATFORM_API_BASE}/binaries/${name}/${version}" -o "$tmp"

  local expected actual
  expected=$(curl -sf --max-time 60 -H "Authorization: Bearer ${PLATFORM_API_TOKEN}" \
    "${PLATFORM_API_BASE}/binaries/${name}/${version}/checksum")
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

download_and_install vm-mcp              "$VM_VER"
download_and_install dns-mcp             "$DNS_VER"
download_and_install update-mcp-binaries "$UPDATE_VER"

# ---------------------------------------------------------------------------
# 4. Systemd service + timer: run as toolserver on boot and daily
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/utherbox-update-mcp.service << 'EOF'
[Unit]
Description=Update Utherbox MCP binaries

[Service]
Type=oneshot
User=toolserver
ExecStart=/usr/local/bin/update-mcp-binaries
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
