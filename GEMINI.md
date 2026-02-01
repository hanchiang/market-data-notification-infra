# Market Data Notification - Infrastructure & Automation

## Project Overview
This repository manages the full-stack infrastructure provisioning and application lifecycle (start/stop) for the **Market Data Notification** system. It utilizes **Infrastructure as Code (IaC)** principles to deploy to AWS.

## Tech Stack
-   **Cloud Provider:** AWS (EC2, Route53, etc.)
-   **Image Building:** HashiCorp Packer
-   **Infrastructure Provisioning:** HashiCorp Terraform
-   **Configuration Management:** Ansible & Bash Scripts
-   **CI/CD:** GitHub Actions

## Directory Structure

### `/images`
Contains Packer configurations to build the base Machine Image (AMI).
-   `image.pkr.hcl`: Main Packer template.
-   `scripts/`: Provisioning scripts run during the Packer build (installing Docker, Nginx, Redis, etc.).

### `/instances`
Contains Terraform configurations to provision the live infrastructure.
-   `main.tf`: Defines AWS resources (EC2 instances, security groups, etc.).
-   `variables.tf`: Input variables for Terraform.
-   `ansible/`: Ansible playbooks and related files for instance configuration.
-   `scripts/`: Operational scripts for managing the lifecycle of the infrastructure.

### `/instances/scripts`
Key automation scripts for day-to-day operations.
-   `full_infra_provision.sh`: High-level orchestration (likely a reference or WIP).
-   `start.sh`: Starts the application/services on the provisioned infrastructure.
-   `stop.sh`: Stops the application/services and potentially tears down resources to save costs.
-   `helper/`: Utility scripts (DNS waiting, timers, EC2 helpers).

### `/.github/workflows`
Automated workflows triggered via GitHub.
-   `start_market_data_notification.yml`: Automates the startup process.
-   `stop_market_data_notification.yml`: Automates the shutdown process.

## Operational Workflows

### 1. Build Machine Image
Run Packer from the `/images` directory:
```bash
packer build -machine-readable -var-file=variables.auto.pkrvars.hcl image.pkr.hcl
```

### 2. Provision Infrastructure
Run Terraform from the `/instances` directory:
```bash
terraform init
terraform apply
```

### 3. Start Application
Use the helper script which sets up the environment and triggers the startup sequence:
```bash
./instances/scripts/start.sh <github_token> <ssh_user> <path_to_private_key>
```

### 4. Stop Application
To stop services or teardown infrastructure:
```bash
./instances/scripts/stop.sh
```

## Development Guidelines
-   **Secrets:** Never commit secrets. The project uses a local `secrets/` directory and `*.tfvars`/`*.pkrvars.hcl` files which are ignored by git.
-   **Idempotency:** When editing scripts (Bash or Ansible), ensure operations are idempotent to avoid failures on re-runs.
-   **Context Awareness:** When asking the agent to perform tasks, specify if you are in the "Image Build" phase or "Instance Provisioning" phase.
