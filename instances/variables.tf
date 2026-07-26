variable "cidr_vpc" {
  description = "CIDR block for the VPC"
  default     = "10.2.0.0/16"
}

variable "cidr_subnet" {
  description = "CIDR block for the subnet"
  default     = "10.2.0.0/24"
}

variable "region" {
  description = "The region Terraform deploys your instance"
  default     = "us-east-1"
}

variable "ec2_instance_type" {
  description = "Instance type"
  default     = "t4g.small"
}

variable "ec2_az" {
  description = "Availability zone"
  default     = "us-east-1a"
}

variable "ssh_private_key_path" {
  description = "Private SSH key for EC2"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Public SSH key for EC2"
  type        = string
}

variable "ssh_user" {
  type = string
}

variable "project_tag" {
  description = <<-EOT
    Value of the Project cost allocation tag applied to every resource in this
    workspace. Tracks the product rather than the git repository, because most
    repos create no AWS resources at all and would report as $0.

    Keep the value stable forever: changing it fragments cost history across two
    tag values that Cost Explorer cannot recombine.

    This state does not cover the whole account. The url-shortener project has
    its own Terraform state and its own resources, which this variable does not
    reach, so an untagged remainder is expected until that state sets its own
    Project value.
  EOT
  type        = string
  default     = "market-data"
}

variable "cost_report_github_subjects" {
  description = <<-EOT
    GitHub OIDC subjects allowed to assume the cost report reader role, in the
    form "repo:OWNER/REPO:ref:refs/heads/BRANCH". Just the default branch of
    the repo holding the cost report workflow: schedule and workflow_dispatch
    both run only from the default branch, so a branch subject could never be
    exercised and would only widen the trust policy.

    Deliberately has no default. This repository is public and the consuming
    repository is private, so hardcoding the subject here would publish a
    private repository name. Set it as a Terraform Cloud workspace variable.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.cost_report_github_subjects) > 0
    error_message = "Provide at least one subject; an empty list would produce a role no workflow can assume."
  }

  # A blank or malformed entry passes the length check but yields a trust policy
  # with an unmatchable sub claim: a role nothing can assume, failing at OIDC
  # exchange time rather than at plan time.
  validation {
    condition = alltrue([
      for subject in var.cost_report_github_subjects :
      can(regex("^repo:[^/]+/[^:]+:", subject))
    ])
    error_message = "Each subject must look like \"repo:OWNER/REPO:ref:refs/heads/BRANCH\"."
  }
}

data "aws_ami" "ec2_ami" {
  name_regex  = "^market_data_notification_t4g_small$"
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
