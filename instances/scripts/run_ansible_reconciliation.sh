#!/bin/bash
set -euo pipefail

# Host-only reconciliation wrapper for the Ansible playbooks used by start.sh.
# This avoids Route53 updates and backend deploy side effects during restore checks.
# It reaches the host through the operator's own SSH alias `production` (~/.ssh/config:
# Session Manager ProxyCommand, host key pinned), so it makes no AWS call of its own.
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
ANSIBLE_VARS_PATH="$ANSIBLE_DIR/vars.yml"
SSH_ALIAS=production
# SSH connect timeout, seconds. Under a ProxyCommand it bounds the whole Session Manager
# handshake. Every host consumer uses the same value; raise them together (the workspace
# runbook's Timeouts list names each one, and a workspace test checks they agree).
SSH_CONNECT_TIMEOUT_SECONDS=23
START_ENV_FILE=${START_ENV_FILE:-"$SCRIPT_DIR/start.local.env"}

if [ -f "$START_ENV_FILE" ]
then
    # shellcheck disable=SC1090
    source "$START_ENV_FILE"
fi

DOMAIN=${DOMAIN:-}
ADMIN_EMAIL=${ADMIN_EMAIL:-}
LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY=${LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY:-}

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
require_cmd ssh
require_env ADMIN_EMAIL "$ADMIN_EMAIL"
require_env DOMAIN "$DOMAIN"

# The alias must be the pinned Session Manager entry from the runbook
# (docs/runbooks/ssh-host-key-pinning.md in the workspace), not a bare hostname.
ssh_settings=$(ssh -G "$SSH_ALIAS")
if ! grep -qx 'stricthostkeychecking true' <<< "$ssh_settings" \
    || ! grep -q '^hostkeyalias market-data-notification-production$' <<< "$ssh_settings"
then
    echo "SSH config entry '$SSH_ALIAS' must set StrictHostKeyChecking yes and HostKeyAlias market-data-notification-production" >&2
    exit 1
fi

mkdir -p "$ANSIBLE_LOCAL_TEMP_DIR"

cat << EOF > "$ANSIBLE_CONFIG_PATH"
[defaults]
host_key_checking = True
local_tmp = $ANSIBLE_LOCAL_TEMP_DIR
# Ansible passes this to ssh as ConnectTimeout; its default is 10.
timeout = $SSH_CONNECT_TIMEOUT_SECONDS

[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
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
    rm -f "$ANSIBLE_CONFIG_PATH" "$ANSIBLE_VARS_PATH"
}

trap cleanup_ansible_inputs EXIT

# Exit 75 from ansible/start.sh (a security playbook failed) is passed through as failure.
ANSIBLE_CONFIG="$ANSIBLE_CONFIG_PATH" \
ANSIBLE_LOCAL_TEMP="$ANSIBLE_LOCAL_TEMP_DIR" \
../ansible/start.sh "$SSH_USER" "$SSH_PRIVATE_KEY_PATH"
