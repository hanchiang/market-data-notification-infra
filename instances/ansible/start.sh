#! /bin/bash

set -euo pipefail

# Run the host Ansible playbooks in order: install backup prerequisites first,
# then reconcile journald, TLS, and nginx as separate machine-config stages.
dir=$(dirname "$0")
cd "$dir"

SSH_USER=$1
SSH_PRIVATE_KEY_PATH=$2

usage () {
    echo "start usage: <path/to/script> domain> <ssh user> <ssh private key path>"
    exit 1
}

if [ -z "$SSH_USER"  ];
then
    usage
fi

if [ -z "$SSH_PRIVATE_KEY_PATH"  ];
then
    usage
fi

# Install the encrypted Let's Encrypt backup prerequisites before TLS reconciliation.
# Backup setup is intentionally non-blocking so a backup-path problem does not
# prevent the runtime from starting. Successful cert issuance or renewal then
# triggers the actual upload via certbot deploy hooks.
if ! ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u "$SSH_USER" -i aws_ec2.yml --private-key "$SSH_PRIVATE_KEY_PATH" playbooks/letsencrypt-backup.yml
then
    echo "Warning: Let's Encrypt backup hook setup failed; continuing startup" >&2
fi

# Reconcile journald retention before the rest of the machine-config path.
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u "$SSH_USER" -i aws_ec2.yml --private-key "$SSH_PRIVATE_KEY_PATH" playbooks/journald.yml

# Bootstrap or reuse TLS state before nginx validation and reload.
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u "$SSH_USER" -i aws_ec2.yml --private-key "$SSH_PRIVATE_KEY_PATH" playbooks/tls.yml

# Reconcile nginx config after TLS state is available.
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u "$SSH_USER" -i aws_ec2.yml --private-key "$SSH_PRIVATE_KEY_PATH" playbooks/nginx.yml
