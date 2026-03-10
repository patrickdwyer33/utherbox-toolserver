#!/usr/bin/env bash
# utherbox-toolserver/setup.sh
# Runs as root via cloud-init on each new project VM.
# Installs MCP binaries (setuid as toolserver) and writes toolserver credentials.
set -euo pipefail

CREDS_FILE="/tmp/utherbox-provision/credentials.json"

# ---------------------------------------------------------------------------
# 1. Install dependencies
# ---------------------------------------------------------------------------
apt-get update -q
apt-get install -y --no-install-recommends awscli jq

# ---------------------------------------------------------------------------
# 2. Parse S3 credentials for binary download
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
# 3. Create toolserver system user
# ---------------------------------------------------------------------------
if ! id -u toolserver &>/dev/null; then
  useradd --system \
          --shell /usr/sbin/nologin \
          --home-dir /home/toolserver \
          --create-home \
          toolserver
fi
chmod 700 /home/toolserver

# ---------------------------------------------------------------------------
# 4. Fetch latest binary versions
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
# 5. Download, verify, and install each binary
# ---------------------------------------------------------------------------
download_and_install() {
  local name="$1"
  local version="$2"
  local dest="/usr/local/bin/${name}"
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
  echo "${name} installed at ${dest} (setuid)"
}

download_and_install vm-mcp  "$VM_VER"
download_and_install dns-mcp "$DNS_VER"

# ---------------------------------------------------------------------------
# 6. Install runtime credentials (full credentials.json for MCP tools)
# ---------------------------------------------------------------------------
install -o toolserver -g toolserver -m 600 \
  "$CREDS_FILE" /home/toolserver/.credentials.json

# ---------------------------------------------------------------------------
# 7. Create cert directory (755 so claude can traverse; dns-mcp sets per-file perms)
# ---------------------------------------------------------------------------
mkdir -p /var/lib/utherbox/certs
chown toolserver:toolserver /var/lib/utherbox/certs
chmod 755 /var/lib/utherbox/certs

# ---------------------------------------------------------------------------
# 8. Harden SSH
# ---------------------------------------------------------------------------
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl reload sshd

# ---------------------------------------------------------------------------
# 9. Ensure claude has no sudo access
# ---------------------------------------------------------------------------
rm -f /etc/sudoers.d/claude

echo "utherbox-toolserver setup complete"
