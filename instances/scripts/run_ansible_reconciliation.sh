#!/bin/bash
set -euo pipefail

# Host-only reconciliation wrapper for the Ansible playbooks used by start.sh.
# This avoids Route53 updates and backend deploy side effects during restore checks.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]
then
    echo "Run this script directly, do not source it." >&2
    return 1 2>/dev/null || exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SSH_USER=${1:-}
SSH_PRIVATE_KEY_PATH=${2:-}
ANSIBLE_DIR="$(cd ../ansible && pwd)"
ANSIBLE_LOCAL_TEMP_DIR=${ANSIBLE_LOCAL_TEMP:-/tmp/ansible-local}
ANSIBLE_CONFIG_PATH="$ANSIBLE_DIR/ansible.cfg"
ANSIBLE_INVENTORY_PATH="$ANSIBLE_DIR/aws_ec2.yml"
ANSIBLE_VARS_PATH="$ANSIBLE_DIR/vars.yml"
START_ENV_FILE=${START_ENV_FILE:-"$SCRIPT_DIR/start.local.env"}

if [ -f "$START_ENV_FILE" ]
then
    # shellcheck disable=SC1090
    source "$START_ENV_FILE"
fi

AWS_REGION=${AWS_REGION:-}
DOMAIN=${DOMAIN:-}
ADMIN_EMAIL=${ADMIN_EMAIL:-}
LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY=${LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY:-}
INSTANCE_TAG_NAME=${INSTANCE_TAG_NAME:-}

usage() {
    echo "usage: <path/to/script> <ssh user> <ssh private key path>" >&2
    exit 1
}

require_cmd() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1
    then
        echo "Missing required command: $name" >&2
        exit 1
    fi
}

require_env() {
    local name="$1"
    local value="$2"
    if [ -z "$value" ]
    then
        echo "Missing required environment variable: $name" >&2
        exit 1
    fi
}

if [ -z "$SSH_USER" ] || [ -z "$SSH_PRIVATE_KEY_PATH" ]
then
    usage
fi

require_cmd ansible-playbook
require_cmd ansible-doc
require_env ADMIN_EMAIL "$ADMIN_EMAIL"
require_env AWS_REGION "$AWS_REGION"
require_env DOMAIN "$DOMAIN"
require_env INSTANCE_TAG_NAME "$INSTANCE_TAG_NAME"

mkdir -p "$ANSIBLE_LOCAL_TEMP_DIR"

cat << EOF > "$ANSIBLE_CONFIG_PATH"
[inventory]
enable_plugins = host_list, script, auto, yaml, ini, toml, amazon.aws.aws_ec2

[defaults]
host_key_checking = False
local_tmp = $ANSIBLE_LOCAL_TEMP_DIR
EOF

if ! ANSIBLE_CONFIG="$ANSIBLE_CONFIG_PATH" ANSIBLE_LOCAL_TEMP="$ANSIBLE_LOCAL_TEMP_DIR" ansible-doc -t inventory -l 2>/dev/null | grep -Eq '^amazon\.aws\.aws_ec2([[:space:]]|$)'
then
    echo "Missing Ansible inventory plugin amazon.aws.aws_ec2. Install it with: ansible-galaxy collection install amazon.aws" >&2
    exit 1
fi

cat << EOF > "$ANSIBLE_INVENTORY_PATH"
plugin: amazon.aws.aws_ec2
hostvars_prefix: aws_
regions:
  - $AWS_REGION
groups:
  market_data_notification: aws_ec2_tags.Name == '$INSTANCE_TAG_NAME'
include_filters:
  - tag:Name:
      - $INSTANCE_TAG_NAME
EOF

cat << EOF > "$ANSIBLE_VARS_PATH"
USER: $SSH_USER
DOMAIN: $DOMAIN
DOMAINS:
  - $DOMAIN
ADMIN_EMAIL: $ADMIN_EMAIL
ansible_python_interpreter: /usr/bin/python3
LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY: "$LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY"
EOF

cleanup_ansible_inputs() {
    rm -f "$ANSIBLE_CONFIG_PATH" "$ANSIBLE_INVENTORY_PATH" "$ANSIBLE_VARS_PATH"
}

trap cleanup_ansible_inputs EXIT

ANSIBLE_CONFIG="$ANSIBLE_CONFIG_PATH" \
ANSIBLE_LOCAL_TEMP="$ANSIBLE_LOCAL_TEMP_DIR" \
../ansible/start.sh "$SSH_USER" "$SSH_PRIVATE_KEY_PATH"
