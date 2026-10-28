#! /bin/bash

set -euo pipefail

# Run the host Ansible playbooks in order against the static one-host inventory. The
# caller (scripts/start.sh or scripts/run_ansible_reconciliation.sh) writes ansible.cfg,
# which keeps host-key checking on.
#
# Exit 75 means the runtime playbooks passed but a security playbook (agent floor, login
# push) failed. scripts/start.sh still dispatches the deploy, then fails the run so the
# workflow alerts: a broken log push must not keep the service down.
dir=$(dirname "$0")
cd "$dir"

SSH_USER=${1:-}
SSH_PRIVATE_KEY_PATH=${2:-}
SECURITY_PLAYBOOK_FAILED=75

usage () {
    echo "usage: <path/to/script> <ssh user> <ssh private key path>" >&2
    exit 1
}

if [ -z "$SSH_USER" ] || [ -z "$SSH_PRIVATE_KEY_PATH" ]
then
    usage
fi

run_playbook () {
    ansible-playbook -u "$SSH_USER" -i inventory.ini --private-key "$SSH_PRIVATE_KEY_PATH" "$@"
}

security_failed=0

# First, because refreshing the agent restarts the session path every later play uses.
if ! run_playbook playbooks/ssm-agent.yml
then
    echo "Warning: Session Manager agent floor failed; continuing startup" >&2
    security_failed=1
fi

# Install the encrypted Let's Encrypt backup prerequisites before TLS reconciliation.
# Backup setup is intentionally non-blocking so a backup-path problem does not
# prevent the runtime from starting. Successful cert issuance or renewal then
# triggers the actual upload via certbot deploy hooks.
if ! run_playbook playbooks/letsencrypt-backup.yml
then
    echo "Warning: Let's Encrypt backup hook setup failed; continuing startup" >&2
fi

# Reconcile journald retention before the rest of the machine-config path.
run_playbook playbooks/journald.yml

# Bootstrap or reuse TLS state before nginx validation and reload.
run_playbook playbooks/tls.yml

# Reconcile nginx config after TLS state is available.
run_playbook playbooks/nginx.yml

if ! run_playbook playbooks/ssh-login-log.yml
then
    echo "Warning: SSH login-line push setup failed; continuing startup" >&2
    security_failed=1
fi

if [ "$security_failed" -ne 0 ]
then
    exit "$SECURITY_PLAYBOOK_FAILED"
fi
