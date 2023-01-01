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
  vpc_id     = aws_vpc.vpc.id
  cidr_block = var.cidr_subnet
  availability_zone = var.ec2_az
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

resource "aws_instance" "web" {
  ami                         = data.aws_ami.ec2_ami.id
  instance_type               = var.ec2_instance_type
  subnet_id                   = aws_subnet.subnet_public.id
  vpc_security_group_ids      = [aws_security_group.sg_22_80_443.id]
  availability_zone = var.ec2_az
  associate_public_ip_address = true

  root_block_device {
    delete_on_termination = true
    volume_size = 8
    volume_type = "gp2"

    tags = {
      Name = "market_data_notification"
    }
  }

  # Wait for EC2 to be ready
  provisioner "remote-exec" {
    inline = ["echo 'EC2 is ready'"]

    connection {
      type = "ssh"
      user = var.ssh_user
      host = self.public_ip
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


