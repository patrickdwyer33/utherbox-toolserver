#!/usr/bin/env bash
# update-mcp-binaries.sh
# Downloads and installs the latest vm-mcp and dns-mcp binaries from S3.
# Must run as toolserver (or root) — reads ~/.credentials.json and overwrites
# /usr/local/bin/{vm-mcp,dns-mcp} which are owned by toolserver.
set -euo pipefail

CREDS_FILE="/home/toolserver/.credentials.json"

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
  local dest="/usr/local/bin/${name}"
  local tmp="/tmp/${name}.update"

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

  # Overwrite in-place: toolserver owns the destination files and can write to
  # them even though /usr/local/bin/ is root-owned (directory write not needed).
  cat "$tmp" > "$dest"
  chmod 4755 "$dest"
  rm -f "$tmp"
  echo "${name} updated to ${version}"
}

update_binary vm-mcp  "$VM_VER"
update_binary dns-mcp "$DNS_VER"

echo "MCP binary update complete"
