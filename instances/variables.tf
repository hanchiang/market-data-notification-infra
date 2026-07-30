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
