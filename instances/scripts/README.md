# Script Overview

The `scripts/` directory automates EC2 runtime bring-up, shutdown, Route53 updates, and backend deployment handoff for [Market data notification](https://github.com/hanchiang/market-data-notification).

Run `start.sh` from `instances/` so the local invocation matches the GitHub Actions workflow.

## `start.sh`
- Starts the EC2 instance if needed
- Waits for the instance to be running
- Updates the Route53 record for the service domain
- Waits for the Session Manager agent to report Online (`helper/wait_for_ssm_online.sh`), not a fixed sleep
- Writes a private SSH config for the instance: Session Manager `ProxyCommand`, host key pinned under `market-data-notification-production`
- Calls `../ansible/start.sh` to reconcile host configuration, with host-key checking on
  - Session Manager agent minimum version (`playbooks/ssm-agent.yml`)
  - SSH login lines shipped to CloudWatch Logs (`playbooks/ssh-login-log.yml`); a failure here or in the agent playbook still dispatches the deploy, then fails the run so it alerts
  - feature-branch Let's Encrypt backup hook setup before TLS reconciliation
  - journald retention reconciliation
  - certbot TLS setup and renew-cron reconciliation
  - nginx config reconciliation, validation, and reload
  - encrypted backup upload triggered on successful certificate issuance or renewal
- Resolves the latest successful backend CI build on `master`
- Dispatches the backend deploy workflow using that image SHA by default
- Accepts `--skip-deploy` to stop after EC2, Route53, and Ansible reconciliation without dispatching the backend deploy workflow

Inputs come from the environment, never from arguments: a token in argv shows in the process list. Any positional argument is refused.

```bash
cd instances
export MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN=... SSH_USER=... SSH_PRIVATE_KEY_PATH=... SSH_KNOWN_HOSTS_FILE=...
scripts/start.sh
scripts/start.sh --skip-deploy   # no token needed
```

- For repeat local runs, prefer an ignored config file at `start.local.env` next to `start.sh`.
- Template: `start.local.env.example`
- Supported variables:
  - `ADMIN_EMAIL` required
  - `AWS_REGION` required
  - `DOMAIN` required
  - `ROUTE53_HOSTED_ZONE_ID` required
  - `LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY` optional
  - `SSH_USER`, `SSH_PRIVATE_KEY_PATH`, `SSH_KNOWN_HOSTS_FILE` required
  - `MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN` required unless `--skip-deploy`
- Local prerequisites:
  - AWS credentials must already be available through the normal AWS SDK/CLI credential chain
  - the Session Manager plugin at the pinned version (`helper/ensure_session_manager_plugin.sh`)

## `run_ansible_reconciliation.sh`
- Runs the host Ansible reconciliation only
- Avoids the Route53 update and backend deploy side effects from `start.sh`
- Use this for restore rehearsal or host-only recovery validation
- Reaches the host through your own SSH alias `production`, which must be the pinned Session Manager entry from the workspace runbook `docs/runbooks/ssh-host-key-pinning.md`; it refuses an entry without strict checking and the alias pin

```bash
cd instances/scripts
./run_ansible_reconciliation.sh <ssh user> <path to ssh private key>
```

## `stop.sh`
- Removes the Route53 record
- Stops the EC2 instance
- Uses the same `start.local.env` convenience file as `start.sh` for `DOMAIN` and `ROUTE53_HOSTED_ZONE_ID`

```bash
./stop.sh
```

## `pin_host_key.sh`
- Reads a new instance's host keys from its first-boot console output and prints the `known_hosts` lines to pin under `market-data-notification-production`, with fingerprints
- Run under the admin identity after a rebuild, before any consumer connects; the full order is in the workspace runbook `docs/runbooks/ssh-host-key-pinning.md` (Rebuild)

```bash
./pin_host_key.sh <instance-id>
```

## `check_host_access_health.sh`
- Run by the start workflow's `check_host_access_health` job on every firing
- Alerts the dev chat when the security group has a port 22 rule, or when no SSH login line reached `/market-data-notification/sshd` in 48 hours

## `download_letsencrypt_backup.sh`
- Downloads the latest encrypted Let's Encrypt backup for a host from S3 by default
- Decrypts it with the operator `age` private key
- Lists the tar members so the backup can be verified quickly
- Optionally extracts the decrypted tarball into an explicit directory for restore rehearsal

```bash
cd instances/scripts
./download_letsencrypt_backup.sh \
  --hostname <hostname> \
  --age-key /secure/path/to/letsencrypt-backup.agekey \
  --region <aws-region>
```

- If `--bucket` is omitted, the script derives `market-data-notification-le-backup-<account-id>-<region>`.
- If `--s3-key` is omitted, the script downloads the most recently uploaded object under `letsencrypt/<hostname>/`.
- By default, it writes the encrypted and decrypted files to the current directory.
- Use `--output-dir` to write them somewhere else.
- Use `--extract-dir <path>` to unpack the decrypted archive after download. Prefer a Linux filesystem path because the preserved `live/<domain>` symlinks can fail on Windows-style extraction paths.
- The repo ignores `*.tar.gz.age` and `*.tar.gz` so downloaded backup artifacts are not staged accidentally.
