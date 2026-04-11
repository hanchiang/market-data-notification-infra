#! /bin/bash

set -euo pipefail

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

# Configure ssl for nginx
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u "$SSH_USER" -i aws_ec2.yml --private-key "$SSH_PRIVATE_KEY_PATH" playbooks/nginx-https.yml

# Install and run the encrypted Let's Encrypt backup flow after TLS reconciliation.
# Backup reconciliation is intentionally non-blocking so a backup-path problem
# does not prevent the runtime from starting.
if ! ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u "$SSH_USER" -i aws_ec2.yml --private-key "$SSH_PRIVATE_KEY_PATH" playbooks/letsencrypt-backup.yml
then
    echo "Warning: Let's Encrypt backup reconciliation failed; continuing startup" >&2
fi

