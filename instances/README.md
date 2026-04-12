# Instance Operations

## Scope
- Run Terraform from `instances/`.
- Treat `instances/scripts/start.sh` and `instances/scripts/stop.sh` as the normal operator entry points for runtime bring-up and shutdown.
- Treat `instances/ansible/` as implementation detail unless you are debugging or making infra changes.

## Prerequisites
- Terraform Cloud access for workspace `hansolo/market_data_notification`
- AWS credentials with permission to read and modify the Terraform-managed resources
- `terraform`
- `aws`
- `jq`
- `curl`
- `ansible-playbook` for local reconciliation or debugging
- the `amazon.aws` Ansible collection for the `aws_ec2` dynamic inventory plugin
- SSH access to the target instance

## Terraform Backend And State
- `instances/main.tf` uses the Terraform Cloud backend for the `hansolo` organization and the `market_data_notification` workspace.
- The authoritative Terraform state lives in Terraform Cloud, not in a local `terraform.tfstate` file.
- Not having a local state file on this machine is normal.
- Do not run `terraform apply` from a directory initialized with `-backend=false`, because that bypasses the remote backend and can produce a misleading local plan.

### Safe State-Sync Checklist
1. Authenticate to Terraform Cloud if this machine has not been used for that workspace before:

   ```bash
   cd instances
   terraform login
   ```

2. Initialize the working directory against the configured remote backend:

   ```bash
   terraform init
   ```

3. Confirm Terraform can read the remote workspace state before planning:

   ```bash
   terraform state pull >/tmp/market_data_notification.tfstate
   ```

4. Review that pulled state file only for confirmation:
   - it should contain existing managed resources
   - if it is empty or the command fails, stop before planning or applying

5. Run a read-only plan:

   ```bash
   terraform plan
   ```

6. Stop if the plan implies Terraform thinks the existing infrastructure is absent or wants broad destructive changes.

### Drift Inspection And State Sync
- When you suspect manual AWS drift, inspect it first with:

  ```bash
  terraform plan -refresh-only
  ```

- If that output only reflects real remote drift that Terraform state should accept, apply the refresh-only change with:

  ```bash
  terraform apply -refresh-only
  ```

- `terraform apply -refresh-only` updates Terraform state to match the real remote objects. It does not modify AWS resources to match the current `.tf` configuration.
- After any refresh-only apply, immediately run a normal plan again:

  ```bash
  terraform plan
  ```

- Do not use refresh-only apply to hide configuration drift you actually intend Terraform to enforce. In particular, immutable EC2 launch attributes can still require replacement in the follow-up normal plan.

### Important Notes
- `terraform init` does not destroy infrastructure.
- The real risk is applying from the wrong backend context, not the absence of a local state file.
- If `terraform state pull` shows the current remote state, Terraform is not treating the cloud as empty.
- Follow `terraform plan -refresh-only` with a normal `terraform plan` when you suspect manual AWS drift.

## Provision Infra
- Apply only after reviewing a non-destructive plan:

  ```bash
  cp terraform.tfvars.example terraform.tfvars
  ```

- Fill in the local values required by `variables.tf` in `terraform.tfvars`.
- `terraform.tfvars` is local-only and ignored by Git through the repo-wide `*.tfvars` rule.
- Keep secret or machine-specific values such as SSH key paths out of tracked files.

  ```bash
  terraform plan
  terraform apply
  ```

## Start Instance
```bash
cd instances
scripts/start.sh <github token> <ssh user> <path to ssh private key>
```

- `start.sh` is the normal runtime bring-up path.
- Running it from `instances/` matches the GitHub Actions workflow path.
- It starts or reuses the EC2 instance, updates Route53, runs Ansible reconciliation, and dispatches backend deployment from the latest successful backend CI SHA on `master`.
- For repeat local runs, prefer an ignored local config file at `instances/scripts/start.local.env` using `instances/scripts/start.local.env.example` as the template.
- Supported config variables are:
  - `ADMIN_EMAIL` required
  - `AWS_REGION` required
  - `DOMAIN` required
  - `INSTANCE_TAG_NAME` required
  - `ROUTE53_HOSTED_ZONE_ID` required
  - `LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY` optional, enables the backup hook when set
- The local script generates temporary `instances/ansible/ansible.cfg`, `aws_ec2.yml`, and `vars.yml` files before Ansible runs, then removes them on exit.
- If local Ansible does not have the `amazon.aws` collection, install it with:

  ```bash
  ansible-galaxy collection install amazon.aws
  ```

## Stop Instance
```bash
scripts/stop.sh
```

- `stop.sh` removes the Route53 record and stops the instance.

## Ansible Reconciliation
- The normal operator flow reaches Ansible through `scripts/start.sh`, which calls `../ansible/start.sh`.
- `ansible/start.sh` currently runs:
  - `playbooks/letsencrypt-backup.yml` on the feature branch when the backup public key is configured
  - `playbooks/nginx-https.yml`
- The backup playbook installs the encrypt-and-upload script, env file, and certbot deploy hook.
- The actual backup upload is triggered by successful certificate issuance or renewal, not by every start run.
  - first issuance seeds a backup immediately after successful `certbot --nginx`
  - later renewals use the certbot deploy hook
- Treat direct playbook execution as a debugging or change-validation path, not the default operator workflow.

## Let's Encrypt Backup Rollout Checklist
1. On a trusted operator machine, generate a dedicated `age` keypair for Let's Encrypt backup decryption:

   ```bash
   age-keygen -o letsencrypt-backup.agekey
   ```

   - Keep `letsencrypt-backup.agekey` private, off-host, and outside the Git working tree when possible.
   - If it is ever created inside the repo by mistake, the repo ignores `*.agekey`, but do not rely on that as the primary safeguard.
   - Record the printed public key (`age1...`) for the backup configuration.

2. Review `main.tf` and confirm the intended live delta is limited to:
   - one S3 backup bucket
   - bucket versioning, server-side encryption, lifecycle retention, and public-access block
   - one IAM role and instance profile
   - attachment of the instance profile to the EC2 instance
   - one public-subnet update to enable automatic public IPv4 assignment on launch, replacing the previous instance-level public-IP setting
3. Set `LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY` to that operator public key in the chosen runtime config:
   - GitHub Actions variable for workflow-driven starts
   - local `instances/scripts/start.local.env` for local `start.sh` runs
4. Keep the existing AMI-time Let's Encrypt copy path in place for the first rollout.
5. Run a read-only `terraform plan` against the real remote workspace.
6. Stop if the plan shows instance replacement, bucket destruction or rename, or drift beyond the listed instance-profile and public-subnet changes.
7. Apply in a low-risk window where a short startup issue is acceptable.
8. Trigger one controlled start flow.
9. Verify TLS still succeeds before treating backup validation as meaningful.
10. Confirm the host now has:
   - `/etc/market-data-notification/letsencrypt-backup.env`
   - `/usr/local/sbin/letsencrypt_backup_to_s3.sh`
   - `/etc/letsencrypt/renewal-hooks/deploy/50-market-data-notification-letsencrypt-backup.sh`
11. If this rollout reused an already-valid certificate and did not issue or renew one during startup, seed the first backup manually on the host:

    ```bash
    sudo /usr/local/sbin/letsencrypt_backup_to_s3.sh
    ```

12. From a trusted operator machine, verify a fresh object exists in:

    ```bash
    aws s3 ls "s3://market-data-notification-le-backup-<account-id>-<region>/letsencrypt/<hostname>/"
    ```

13. Download one encrypted archive, decrypt it with the operator private key, and inspect the tar members for:

    ```bash
    aws s3 cp "s3://market-data-notification-le-backup-<account-id>-<region>/letsencrypt/<hostname>/<timestamp>.tar.gz.age" .
    age -d -i letsencrypt-backup.agekey -o letsencrypt-backup.tar.gz "<timestamp>.tar.gz.age"
    tar -tzf letsencrypt-backup.tar.gz
    ```

    - `accounts/`
    - `live/<domain>/`
    - `archive/<domain>/`
    - `renewal/<domain>.conf`
14. Confirm the seed or hook-triggered upload succeeds and prints or results in the expected S3 object path.
15. Rehearse restore on a non-production target if possible:
    - restore the decrypted Let's Encrypt state onto the target host
    - rerun TLS reconciliation
    - confirm nginx starts with the restored cert material
16. Treat forced renewal as troubleshooting guidance, not the primary restore-validation step.
17. Only after a successful restore rehearsal, decide whether to retire the older Packer-time Let's Encrypt copy path.
