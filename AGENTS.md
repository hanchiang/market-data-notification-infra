# market-data-notification-infra Agent Guide

Last verified: 2026-04-01

## Scope
- Applies to `market-data-notification-infra/` unless a deeper `AGENTS.md` overrides it.
- Follow the workspace root `AGENTS.md` first for cross-repo rules.
- Use workspace-root task memory for canonical active work. Any repo-local `ACTIVE_TASK.md` or `ACTIVE_TASKS/` paths are scratch only unless the human explicitly asks for them.

## Repo Role
- Infrastructure and automation repo for the notification backend on AWS.
- Covers AMI build, EC2 provisioning, DNS updates, post-provisioning configuration, and start-stop orchestration.

## Important Paths
- `images/image.pkr.hcl`: Packer template for the base image.
- `images/scripts/`: AMI provisioning scripts.
- `instances/main.tf`: Terraform entry point.
- `instances/variables.tf`: infrastructure variables.
- `instances/ansible/`: post-provisioning configuration.
- `instances/scripts/start.sh`: start sequence for EC2, Route53, Ansible, and deployment dispatch.
- `instances/scripts/stop.sh`: shutdown sequence.

## Repo-Specific Rules
- Treat this repo as high-blast-radius. Prefer read, format, and validate actions over live execution.
- Separate structural cleanup from operational changes whenever possible. The shell scripts currently combine several responsibilities in a single flow.
- Do not run AWS, Route53, or GitHub Actions dispatch commands unless the user explicitly wants live operations.
- Preserve idempotency when editing shell scripts, Ansible, Packer, or Terraform.

## Validation
- Use workspace `EVALS.md` as the default validation matrix for this repo.
- If a validation step cannot run because cloud credentials or provider initialization are missing, state that explicitly.

## Stop And Ask
- The task requires `terraform apply`, `terraform destroy`, `packer build`, Route53 changes, or GitHub workflow dispatch.
- The task would change production-facing DNS, instance lifecycle, or deployment sequencing without a clear rollback path.
- A proposed fix weakens secret handling or embeds credentials into scripts or config.
