#! /bin/bash

set -euo pipefail

# Make sure the pinned Session Manager plugin is the one on PATH. GitHub's runner image
# ships it today, but the image floats; a different or missing version is replaced by the
# pinned .deb after its SHA-256 and AWS's signature both check out.
# Pins and verdict: third-party audit of 2026-10-28, summarised in the workspace runbook
# docs/runbooks/ssh-host-key-pinning.md, section "Third-party tool: Session Manager
# plugin". The infra repo (instances/scripts/helper/) and the backend repo (scripts/ci/)
# keep byte-identical copies of this script and the key beside it; change both together
# (the workspace test scripts/test_check_host_consumers.py compares them).
SMP_VERSION=1.2.896.0
SMP_DEB_SHA256=53f51fcc67314a4bf85888a38a3967cd41f8d0f28a60a9469a63acf935ba713e
SMP_KEY_FINGERPRINT=7959637124CE093AD501D47A2C4D4AFF6F6757EE
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMP_KEY_FILE="$SCRIPT_DIR/session-manager-plugin.asc"

# This variable widens which stream hosts the plugin trusts.
if [ -n "${AWS_SSM_PLUGIN_ADDITIONAL_STREAM_HOSTS:-}" ]
then
    echo "AWS_SSM_PLUGIN_ADDITIONAL_STREAM_HOSTS must not be set" >&2
    exit 1
fi

if [ "$(session-manager-plugin --version 2>/dev/null || true)" != "$SMP_VERSION" ]
then
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    base="https://s3.amazonaws.com/session-manager-downloads/plugin/${SMP_VERSION}/ubuntu_64bit"
    curl -fsSLo "$work/session-manager-plugin.deb" "$base/session-manager-plugin.deb"
    curl -fsSLo "$work/session-manager-plugin.deb.sig" "$base/session-manager-plugin.deb.sig"
    echo "${SMP_DEB_SHA256}  $work/session-manager-plugin.deb" | sha256sum -c -
    export GNUPGHOME="$work/gnupg"
    mkdir -m 700 "$GNUPGHOME"
    gpg --batch --quiet --import "$SMP_KEY_FILE"
    # The exact fingerprint, not gpg's exit code, which any key in the keyring would satisfy.
    # Captured first: `| grep -q` under pipefail can fail a good run when grep exits early.
    status="$(gpg --batch --status-fd 1 --verify "$work/session-manager-plugin.deb.sig" "$work/session-manager-plugin.deb" 2>/dev/null || true)"
    if ! grep -q "^\[GNUPG:\] VALIDSIG ${SMP_KEY_FINGERPRINT} " <<< "$status"
    then
        echo "session-manager-plugin.deb signature is not from ${SMP_KEY_FINGERPRINT}" >&2
        exit 1
    fi
    sudo dpkg -i "$work/session-manager-plugin.deb"
fi

installed="$(session-manager-plugin --version)"
if [ "$installed" != "$SMP_VERSION" ]
then
    echo "session-manager-plugin is $installed, expected $SMP_VERSION" >&2
    exit 1
fi
echo "session-manager-plugin $installed"
