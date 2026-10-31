#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
usage: download_letsencrypt_backup.sh --hostname <hostname> --age-key <path> [options]

Downloads and decrypts a Let's Encrypt backup archive from S3.

Required:
  --hostname <hostname>     Hostname segment used in the S3 key prefix.
  --age-key <path>          Path to the operator age private key.

Optional:
  --bucket <name>           Override the backup bucket name.
  --region <region>         AWS region used to derive the default bucket name.
  --s3-key <key>            Download a specific S3 object key instead of the latest one.
  --output-dir <path>       Directory for the downloaded and decrypted files. Default: current directory.
  --extract-dir <path>      Extract the decrypted tarball into the given directory after download.
  --s3-prefix <prefix>      Backup object prefix. Default: letsencrypt.
  --skip-list               Skip listing decrypted tar members after download.
  -h, --help                Show this help text.
EOF
}

require_cmd() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1
    then
        echo "Missing required command: $name" >&2
        exit 1
    fi
}

require_file() {
    local path="$1"
    if [[ ! -f "$path" ]]
    then
        echo "Missing required file: $path" >&2
        exit 1
    fi
}

get_default_region() {
    if [[ -n "${AWS_REGION:-}" ]]
    then
        printf '%s\n' "$AWS_REGION"
        return 0
    fi

    if [[ -n "${AWS_DEFAULT_REGION:-}" ]]
    then
        printf '%s\n' "$AWS_DEFAULT_REGION"
        return 0
    fi

    aws configure get region 2>/dev/null || true
}

resolve_bucket_name() {
    local region="$1"
    local account_id
    account_id="$(aws sts get-caller-identity --query Account --output text)"
    printf 'market-data-notification-le-backup-%s-%s\n' "$account_id" "$region"
}

resolve_latest_s3_key() {
    local bucket_name="$1"
    local s3_prefix="$2"
    local hostname="$3"

    local key
    key="$(aws s3api list-objects-v2 \
        --bucket "$bucket_name" \
        --prefix "${s3_prefix}/${hostname}/" \
        --query 'reverse(sort_by(Contents, &LastModified))[0].Key' \
        --output text)"

    if [[ -z "$key" || "$key" == "None" ]]
    then
        echo "No Let's Encrypt backup objects found under s3://${bucket_name}/${s3_prefix}/${hostname}/" >&2
        exit 1
    fi

    printf '%s\n' "$key"
}

HOSTNAME_SHORT=""
AGE_KEY_PATH=""
BUCKET_NAME=""
AWS_REGION_ARG=""
S3_KEY=""
OUTPUT_DIR="$PWD"
EXTRACT_DIR=""
S3_PREFIX="${LETSENCRYPT_BACKUP_S3_PREFIX:-letsencrypt}"
LIST_TAR_CONTENTS=true

while [[ $# -gt 0 ]]
do
    case "$1" in
        --hostname)
            HOSTNAME_SHORT="${2:-}"
            shift 2
            ;;
        --age-key)
            AGE_KEY_PATH="${2:-}"
            shift 2
            ;;
        --bucket)
            BUCKET_NAME="${2:-}"
            shift 2
            ;;
        --region)
            AWS_REGION_ARG="${2:-}"
            shift 2
            ;;
        --s3-key)
            S3_KEY="${2:-}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --extract-dir)
            EXTRACT_DIR="${2:-}"
            shift 2
            ;;
        --s3-prefix)
            S3_PREFIX="${2:-}"
            shift 2
            ;;
        --skip-list)
            LIST_TAR_CONTENTS=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$HOSTNAME_SHORT" || -z "$AGE_KEY_PATH" ]]
then
    usage >&2
    exit 1
fi

require_cmd aws
require_cmd age
require_cmd tar
require_file "$AGE_KEY_PATH"

if [[ -z "$BUCKET_NAME" ]]
then
    if [[ -z "$AWS_REGION_ARG" ]]
    then
        AWS_REGION_ARG="$(get_default_region)"
    fi

    if [[ -z "$AWS_REGION_ARG" ]]
    then
        echo "AWS region is required when --bucket is not provided" >&2
        exit 1
    fi

    BUCKET_NAME="$(resolve_bucket_name "$AWS_REGION_ARG")"
fi

if [[ -z "$S3_KEY" ]]
then
    S3_KEY="$(resolve_latest_s3_key "$BUCKET_NAME" "$S3_PREFIX" "$HOSTNAME_SHORT")"
fi

mkdir -p "$OUTPUT_DIR"

ENCRYPTED_BASENAME="$(basename "$S3_KEY")"
ENCRYPTED_PATH="${OUTPUT_DIR}/${ENCRYPTED_BASENAME}"
DECRYPTED_PATH="${OUTPUT_DIR}/${ENCRYPTED_BASENAME%.age}"

aws s3 cp \
    --only-show-errors \
    "s3://${BUCKET_NAME}/${S3_KEY}" \
    "$ENCRYPTED_PATH"

age -d -i "$AGE_KEY_PATH" -o "$DECRYPTED_PATH" "$ENCRYPTED_PATH"

echo "Downloaded encrypted backup: $ENCRYPTED_PATH"
echo "Decrypted archive: $DECRYPTED_PATH"

if [[ "$LIST_TAR_CONTENTS" == true ]]
then
    echo "Archive contents:"
    tar -tzf "$DECRYPTED_PATH"
fi

if [[ -n "$EXTRACT_DIR" ]]
then
    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$DECRYPTED_PATH" -C "$EXTRACT_DIR"
    echo "Extracted archive to: $EXTRACT_DIR"
fi
