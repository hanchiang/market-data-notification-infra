variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ssh_public_key_src_path" {
  type = string
  default = ""
}

variable "ssh_public_key_dest_path" {
  type = string
  default = "/tmp/market_data_notification.pub"
}

variable "admin_email" {
  type = string
  default = ""
}

# source blocks are generated from your builders; a source can be referenced in
# build blocks. A build block runs provisioners and post-processors on a
# source.
source "amazon-ebs" "market_data_notification" {
  ami_name      = "market_data_notification"
  instance_type = "t2.micro"
  region        = var.region
  force_deregister   = true
  force_delete_snapshot = true
  ssh_username = "ubuntu"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/*ubuntu-focal-20.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }

  tags = {
    Name = "market_data_notification"
  }
}

build {
    sources = ["source.amazon-ebs.market_data_notification"]

    provisioner "file" {
      source = var.ssh_public_key_src_path
      destination = var.ssh_public_key_dest_path
    }

    provisioner "shell" {
      scripts = ["./scripts/setup-user.sh"]
      env = {
        SSH_PUBLIC_KEY_PATH: var.ssh_public_key_dest_path
        USER: "han"
      }
    }

    provisioner "shell" {
      scripts = ["./scripts/install-nginx.sh"]
      env = {
        USER: "han",
        DOMAIN: "api.marketdata.yaphc.com"
      }
    }

    provisioner "shell" {
      scripts = ["./scripts/install-redis.sh"]
    }

    provisioner "shell" {
      scripts = ["./scripts/install-docker.sh"]
      env = {
        USER: "han"
      }
    }

    provisioner "shell" {
      inline = [
        "sudo lsblk -f",
        "df -h"
      ]
    }
}
