terraform {
  cloud {
    organization = "hansolo"

    workspaces {
      name = "market_data_notification"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.20.1"
    }
  }
  required_version = ">= 0.14.5"
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  letsencrypt_backup_bucket_name = "market-data-notification-le-backup-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
}

resource "aws_vpc" "vpc" {
  cidr_block           = var.cidr_vpc
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "market_data_notification"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "market_data_notification"
  }
}

resource "aws_subnet" "subnet_public" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = var.cidr_subnet
  availability_zone       = var.ec2_az
  map_public_ip_on_launch = true
  tags = {
    Name = "market_data_notification"
  }
}

resource "aws_route_table" "rtb_public" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "rta_subnet_public" {
  subnet_id      = aws_subnet.subnet_public.id
  route_table_id = aws_route_table.rtb_public.id
}

resource "aws_security_group" "sg_22_80_443" {
  name   = "sg_22_80_443"
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "market_data_notification"
  }
}

resource "aws_s3_bucket" "letsencrypt_backup" {
  bucket = local.letsencrypt_backup_bucket_name

  tags = {
    Name = "market_data_notification_letsencrypt_backup"
  }
}

resource "aws_s3_bucket_versioning" "letsencrypt_backup" {
  bucket = aws_s3_bucket.letsencrypt_backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "letsencrypt_backup" {
  bucket = aws_s3_bucket.letsencrypt_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "letsencrypt_backup" {
  bucket = aws_s3_bucket.letsencrypt_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "letsencrypt_backup" {
  bucket = aws_s3_bucket.letsencrypt_backup.id

  rule {
    id     = "expire-letsencrypt-backups"
    status = "Enabled"

    expiration {
      days = 60
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_iam_role" "letsencrypt_backup" {
  name = "market_data_notification_letsencrypt_backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "letsencrypt_backup" {
  name = "market_data_notification_letsencrypt_backup"
  role = aws_iam_role.letsencrypt_backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.letsencrypt_backup.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.letsencrypt_backup.arn}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "letsencrypt_backup" {
  name = "market_data_notification_letsencrypt_backup"
  role = aws_iam_role.letsencrypt_backup.name
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.ec2_ami.id
  instance_type          = var.ec2_instance_type
  subnet_id              = aws_subnet.subnet_public.id
  vpc_security_group_ids = [aws_security_group.sg_22_80_443.id]
  availability_zone      = var.ec2_az
  iam_instance_profile   = aws_iam_instance_profile.letsencrypt_backup.name
  credit_specification {
    cpu_credits = "standard"
  }

  root_block_device {
    delete_on_termination = true
    volume_size           = 20
    volume_type           = "gp2"

    tags = {
      Name = "market_data_notification"
    }
  }

  # Wait for EC2 to be ready
  provisioner "remote-exec" {
    inline = ["echo 'EC2 is ready'"]

    connection {
      type        = "ssh"
      user        = var.ssh_user
      host        = self.public_ip
      private_key = file(var.ssh_private_key_path)
    }
  }

  tags = {
    Name = "market_data_notification"
  }
}

output "public_ip" {
  value = aws_instance.web.public_ip
}

output "public_dns" {
  value = aws_instance.web.public_dns
}

output "ebs_root_device_id" {
  value = aws_instance.web.root_block_device.0.volume_id
}

output "ebs_root_device_name" {
  value = aws_instance.web.root_block_device.0.device_name
}

output "letsencrypt_backup_bucket_name" {
  value = aws_s3_bucket.letsencrypt_backup.bucket
}
