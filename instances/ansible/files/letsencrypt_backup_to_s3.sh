#!/bin/bash
set -euo pipefail

readonly DEFAULT_ENV_FILE="/etc/market-data-notification/letsencrypt-backup.env"
ENV_FILE="${LETSENCRYPT_BACKUP_ENV_FILE:-$DEFAULT_ENV_FILE}"
LETSENCRYPT_ROOT="${LETSENCRYPT_BACKUP_ROOT:-/etc/letsencrypt}"
AWS_CLI_BIN="${LETSENCRYPT_BACKUP_AWS_CLI_BIN:-aws}"
BUCKET_NAME_OVERRIDE="${LETSENCRYPT_BACKUP_BUCKET_NAME:-}"
REGION_OVERRIDE="${LETSENCRYPT_BACKUP_REGION:-}"
HOSTNAME_OVERRIDE="${LETSENCRYPT_BACKUP_HOSTNAME:-}"
S3_PREFIX="${LETSENCRYPT_BACKUP_S3_PREFIX:-letsencrypt}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required setting: $name" >&2
    exit 1
  fi
}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name" >&2
    exit 1
  fi
}

require_cmd age
require_cmd "$AWS_CLI_BIN"
require_cmd curl
require_cmd tar

require_var LETSENCRYPT_BACKUP_AGE_RECIPIENT
require_var LETSENCRYPT_BACKUP_DOMAINS

get_imds_token() {
  curl -fsS -X PUT \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
    "http://169.254.169.254/latest/api/token"
}

get_region() {
  if [[ -n "$REGION_OVERRIDE" ]]; then
    printf '%s\n' "$REGION_OVERRIDE"
    return 0
  fi

  local token="$1"
  curl -fsS \
    -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/dynamic/instance-identity/document" | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["region"])'
}

get_bucket_name() {
  if [[ -n "$BUCKET_NAME_OVERRIDE" ]]; then
    printf '%s\n' "$BUCKET_NAME_OVERRIDE"
    return 0
  fi

  local region="$1"
  local account_id
  account_id="$("$AWS_CLI_BIN" sts get-caller-identity --query Account --output text)"
  printf 'market-data-notification-le-backup-%s-%s\n' "$account_id" "$region"
}

get_hostname_short() {
  if [[ -n "$HOSTNAME_OVERRIDE" ]]; then
    printf '%s\n' "$HOSTNAME_OVERRIDE"
    return 0
  fi

  hostname -s
}

verify_backup_paths() {
  local domain
  for domain in $LETSENCRYPT_BACKUP_DOMAINS; do
    [[ -d "$LETSENCRYPT_ROOT/live/$domain" ]] || {
      echo "Missing live certificate directory for $domain" >&2
      exit 1
    }
    [[ -d "$LETSENCRYPT_ROOT/archive/$domain" ]] || {
      echo "Missing archive directory for $domain" >&2
      exit 1
    }
    [[ -f "$LETSENCRYPT_ROOT/renewal/$domain.conf" ]] || {
      echo "Missing renewal config for $domain" >&2
      exit 1
    }
    [[ -s "$LETSENCRYPT_ROOT/live/$domain/fullchain.pem" ]] || {
      echo "Missing fullchain.pem for $domain" >&2
      exit 1
    }
    [[ -s "$LETSENCRYPT_ROOT/live/$domain/privkey.pem" ]] || {
      echo "Missing privkey.pem for $domain" >&2
      exit 1
    }
  done

  [[ -d "$LETSENCRYPT_ROOT/accounts" ]] || {
    echo "Missing letsencrypt accounts directory" >&2
    exit 1
  }
}

build_tar_args() {
  TAR_PATHS=("accounts")

  local domain
  for domain in $LETSENCRYPT_BACKUP_DOMAINS; do
    TAR_PATHS+=(
      "live/$domain"
      "archive/$domain"
      "renewal/$domain.conf"
    )
  done
}

main() {
  verify_backup_paths
  build_tar_args

  local region
  local token=""
  if [[ -z "$REGION_OVERRIDE" ]]; then
    token="$(get_imds_token)"
  fi
  region="$(get_region "$token")"

  local bucket_name
  bucket_name="$(get_bucket_name "$region")"
  local hostname_short
  hostname_short="$(get_hostname_short)"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"

  local workdir
  workdir="$(mktemp -d /tmp/letsencrypt-backup.XXXXXX)"
  local cleanup_workdir="$workdir"
  local archive_path="$workdir/letsencrypt-backup-${timestamp}.tar.gz"
  local encrypted_path="${archive_path}.age"
  local s3_key="${S3_PREFIX}/${hostname_short}/${timestamp}.tar.gz.age"

  cleanup() {
    rm -rf "${cleanup_workdir:-}"
  }
  trap cleanup EXIT

  tar -czf "$archive_path" -C "$LETSENCRYPT_ROOT" "${TAR_PATHS[@]}"
  age -r "$LETSENCRYPT_BACKUP_AGE_RECIPIENT" -o "$encrypted_path" "$archive_path"

  "$AWS_CLI_BIN" s3 cp \
    --only-show-errors \
    --sse AES256 \
    "$encrypted_path" \
    "s3://${bucket_name}/${s3_key}"

  echo "Uploaded encrypted Let's Encrypt backup to s3://${bucket_name}/${s3_key}"
}

main "$@"
