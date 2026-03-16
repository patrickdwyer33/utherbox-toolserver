#!/usr/bin/env bash
# update-mcp-binaries.sh
# Downloads and installs the latest vm-mcp and dns-mcp binaries from S3.
# Must run as toolserver (or root) — reads ~/.credentials.json.
#
# Binaries are installed to /home/toolserver/bin/ (toolserver-owned) and
# atomically replaced with mv (rename), which avoids ETXTBSY even when
# the currently-running binary is being replaced.
# /usr/local/bin/{name} symlinks into /home/toolserver/bin/.
set -euo pipefail

CREDS_FILE="/home/toolserver/.credentials.json"
BIN_DIR="/home/toolserver/bin"

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

LATEST=$(AWS_ACCESS_KEY_ID="$S3_ACCESS" AWS_SECRET_ACCESS_KEY="$S3_SECRET" \
  aws s3 cp "s3://${S3_BUCKET}/latest.json" - --endpoint-url "$S3_ENDPOINT")
VM_VER=$(echo "$LATEST" | jq -r '."vm-mcp"')
DNS_VER=$(echo "$LATEST" | jq -r '."dns-mcp"')

if [[ "$VM_VER" == "null" || -z "$VM_VER" || "$DNS_VER" == "null" || -z "$DNS_VER" ]]; then
  echo "ERROR: latest.json is missing vm-mcp or dns-mcp version" >&2
  exit 1
fi

echo "Updating to vm-mcp@${VM_VER} dns-mcp@${DNS_VER}"

update_binary() {
  local name="$1"
  local version="$2"
  local dest="${BIN_DIR}/${name}"
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

  chmod 4755 "$tmp"
  # Atomic rename — avoids ETXTBSY on the running binary. The old inode stays
  # open in any running process; the new inode is used on the next exec.
  mv "$tmp" "$dest"
  echo "${name} updated to ${version}"
}

update_binary vm-mcp  "$VM_VER"
update_binary dns-mcp "$DNS_VER"

echo "MCP binary update complete"
