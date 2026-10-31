#! /bin/bash

set -euo pipefail

# Read a new instance's SSH host keys out of band and print the known_hosts lines to pin,
# keyed by the stable alias, with their fingerprints.
# The source is the instance's first-boot console output, where cloud-init prints the
# keys between the BEGIN/END SSH HOST KEY KEYS markers. Run under the admin identity,
# after wait_for_ssm_online.sh and before any consumer connects.
#
# usage: pin_host_key.sh <instance-id>
#        pin_host_key.sh --console-file <saved console output>
# Exit 0 lines printed; 2 no key block (a later boot replaced the log: fall back to an
# admin shell session running ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub);
# 3 a key's fingerprint disagrees with the console's own fingerprint block; 1 other errors.

HOST_KEY_ALIAS=market-data-notification-production
# DSA is excluded: OpenSSH's client no longer negotiates it, so a DSA pin protects nothing.
KEY_PATTERN='(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) AAAA[0-9A-Za-z+/]+=*'

usage () {
    echo "usage: $(basename "$0") <instance-id> | --console-file <path>" >&2
    exit 1
}

case "${1:-}" in
    --console-file)
        [ $# -eq 2 ] || usage
        console=$(cat "$2")
        ;;
    ''|-*)
        usage
        ;;
    *)
        [ $# -eq 1 ] || usage
        # The CLI decodes the base64 Output field.
        console=$(aws ec2 get-console-output --instance-id "$1" --query Output --output text)
        ;;
esac

# Lines of the last block between two markers; consoles prefix lines with "ec2: " or a
# timestamp, so the key and fingerprint patterns are matched anywhere on the line.
last_block () {
    awk -v begin="-----BEGIN $1-----" -v end="-----END $1-----" '
        index($0, begin) { block = ""; inside = 1; next }
        index($0, end)   { last = block; inside = 0; next }
        inside           { block = block $0 "\n" }
        END              { printf "%s", last }
    ' <<< "$console"
}

keys=$(last_block "SSH HOST KEY KEYS" | grep -oE "$KEY_PATTERN" || true)
if [ -z "$keys" ]
then
    echo "No SSH host key block in the console output. A later boot may have replaced it." >&2
    echo "Fallback: an admin shell session running ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub" >&2
    exit 2
fi
printed_fingerprints=$(last_block "SSH HOST KEY FINGERPRINTS" | grep -oE 'SHA256:[0-9A-Za-z+/]+' || true)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pin_lines="$work/known_hosts"
: > "$pin_lines"
fingerprints=""
while IFS= read -r key
do
    line="$HOST_KEY_ALIAS $key"
    printf '%s\n' "$line" > "$work/one"
    # ssh-keygen rejects a malformed key, so a garbled console line stops here.
    fingerprint=$(ssh-keygen -lf "$work/one")
    sha=$(grep -oE 'SHA256:[0-9A-Za-z+/]+' <<< "$fingerprint")
    if [ -n "$printed_fingerprints" ] && ! grep -qxF "$sha" <<< "$printed_fingerprints"
    then
        echo "Fingerprint $sha of a printed key is not in the console's fingerprint block; refusing to pin" >&2
        exit 3
    fi
    fingerprints+="$fingerprint"$'\n'
    printf '%s\n' "$line" >> "$pin_lines"
done <<< "$keys"

echo "# Fingerprints: compare each with a second source before pinning"
printf '%s' "$fingerprints"
echo "# known_hosts lines for SSH_KNOWN_HOSTS (both repos) and each machine's ~/.ssh/known_hosts"
cat "$pin_lines"
