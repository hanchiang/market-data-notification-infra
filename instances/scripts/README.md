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
  - `INSTANCE_TAG_NAME` required
  - `ROUTE53_HOSTED_ZONE_ID` required
  - `LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY` optional
- Local prerequisites:
  - AWS credentials must already be available through the normal AWS SDK/CLI credential chain
  - local Ansible must have the `amazon.aws` collection installed for the `aws_ec2` inventory plugin

## `stop.sh`
- Removes the Route53 record
- Stops the EC2 instance

```bash
./stop.sh
```
