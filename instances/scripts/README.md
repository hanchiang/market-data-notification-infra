# Script Overview

The `scripts/` directory automates EC2 runtime bring-up, shutdown, Route53 updates, and backend deployment handoff for [Market data notification](https://github.com/hanchiang/market-data-notification).

Run `start.sh` from `instances/` so the local invocation matches the GitHub Actions workflow.

## `start.sh`
- Starts the EC2 instance if needed
- Waits for the instance to be running
- Updates the Route53 record for the service domain
- Calls `../ansible/start.sh` to reconcile host configuration
  - feature-branch Let's Encrypt backup hook setup before TLS reconciliation
  - nginx and certbot TLS setup, with encrypted backup upload triggered on successful certificate issuance or renewal
- Resolves the latest successful backend CI build on `master`
- Dispatches the backend deploy workflow using that image SHA

Inputs:

```bash
cd instances
scripts/start.sh <github token> <ssh user> <path to ssh private key>
```

- For repeat local runs, prefer an ignored config file at `start.local.env` next to `start.sh`.
- Template: `start.local.env.example`
- Supported variables:
  - `ADMIN_EMAIL` required
  - `AWS_REGION` required
  - `DOMAIN` required
  - `INSTANCE_TAG_NAME` optional override; defaults to the Terraform-managed EC2 `Name` tag `market_data_notification`
  - `ROUTE53_HOSTED_ZONE_ID` required
  - `LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY` optional
- Local prerequisites:
  - AWS credentials must already be available through the normal AWS SDK/CLI credential chain
  - local Ansible must have the `amazon.aws` collection installed for the `aws_ec2` inventory plugin

## `run_ansible_reconciliation.sh`
- Runs the host Ansible reconciliation only
- Avoids the Route53 update and backend deploy side effects from `start.sh`
- Use this for restore rehearsal or host-only recovery validation

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
