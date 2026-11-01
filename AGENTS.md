# market-data-notification-infra Agent Guide

Last verified: 2026-10-28

## Scope
- Applies to `market-data-notification-infra/` unless a deeper `AGENTS.md` overrides it.
- Follow the workspace root `AGENTS.md` first for cross-repo rules.

## Repo Role
- Infrastructure and automation repo for the notification backend on AWS.
- Covers AMI build, EC2 provisioning, DNS updates, post-provisioning configuration, and start-stop orchestration.
- The EC2 managed here also hosts `ai-automation` as a second tenant (separate Linux user, separate Postgres database). Before making changes that affect instance sizing, OS packages, Postgres version, or shared system resources, check that the change is safe for both tenants. See [ai-automation ADR 0007](../../AI-AUTOMATION/ai-automation/docs/decisions/0007-vm-deployment-strategy.md) for the tenancy decision and isolation contract.

## Important Paths
- `images/image.pkr.hcl`: Packer template for the base image.
- `images/scripts/`: AMI provisioning scripts.
- `instances/main.tf`: Terraform entry point.
- `instances/variables.tf`: infrastructure variables.
- `instances/ansible/`: post-provisioning configuration.
- `instances/scripts/start.sh`: start sequence for EC2, Route53, Ansible, and deployment dispatch.
- `instances/scripts/stop.sh`: shutdown sequence.
- `instances/access.tf`: Session Manager callers, the fixed-port session document, the agent's grant, and the SSH login-line log group.
- `scripts/check_ssh_policy.py`, `tests/`: the SSH policy check and the scripts' tests (`python3 -m unittest discover -s tests`).

## Repo-Specific Rules
- Treat this repo as high-blast-radius. Prefer read, format, and validate actions over live execution.
- Separate structural cleanup from operational changes whenever possible. The shell scripts currently combine several responsibilities in a single flow.
- Do not run AWS, Route53, or GitHub Actions dispatch commands unless the user explicitly wants live operations.
- Preserve idempotency when editing shell scripts, Ansible, Packer, or Terraform.
- **No public SSH, and every SSH path pinned.** Every tracked ssh, scp and Ansible path reaches the host over AWS Session Manager (`instances/access.tf`) and checks the host key against the pin filed under `market-data-notification-production`; break-glass is the only other way in. Never add a security-group ingress that admits port 22 from an address range, never turn host-key checking off or to accept-new, and never trust a key read off the network. `.github/workflows/ssh-policy.yml` runs `scripts/check_ssh_policy.py` on every push and fails on any of these. A break-glass rule is made out of band, never committed. How to reach the host and re-pin after a rebuild: the workspace runbook `docs/runbooks/ssh-host-key-pinning.md`. Failures and break-glass: `docs/runbooks/ssh-access-failures.md`.

## Validation
- Packer formatting: `packer fmt -check images/image.pkr.hcl`
- Terraform formatting: `terraform fmt -check instances`
- Terraform validation: run from `instances/` with initialized providers, `terraform validate`
- Shell scripts: `shellcheck` for touched scripts when available
- If a validation step cannot run because cloud credentials or provider initialization are missing, state that explicitly.

## Stop And Ask
- The task requires `terraform apply`, `terraform destroy`, `packer build`, Route53 changes, or GitHub workflow dispatch.
- The task would change production-facing DNS, instance lifecycle, or deployment sequencing without a clear rollback path.
- A proposed fix weakens secret handling or embeds credentials into scripts or config.
