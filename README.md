This project is the infrastructure as code management for [Market data notification](https://github.com/hanchiang/market-data-notification) using AWS.

![example workflow](https://github.com/hanchiang/market-data-notification-infra/actions/workflows/start_market_data_notification.yml/badge.svg)
![example workflow](https://github.com/hanchiang/market-data-notification-infra/actions/workflows/stop_market_data_notification.yml/badge.svg)

# Structure
* `images/`: Packer files for building AMI
    * `image.pkr.hcl`: Main packer script
    * `scripts/`: Scripts to be run when provisioning AMI
* `instances/`: Terraform files to provision EC2 in VPC
    * `main.tf`: Main terraform script
    * `ansible/`: Ansible scripts to run post-provisioning tasks such as mounting EBS volume, set up file system, copy postgres data, setup SSL for nginx 
    * `scripts/`: Scripts to automate(everything after step 2 of the workflow) start and stop of EC2, DNS, and deployment of [Market data notification](https://github.com/hanchiang/market-data-notification). Calls ansible scripts


# Workflow
## 1. Provision EC2 AMI using packer
Provisions a EBS-backed EC2 AMI, and install the necessary softwares for [Market data notification](https://github.com/hanchiang/market-data-notification), e.g. docker, nginx

cd into `images/`
Define variables that are declared in `image.pkr.hcl` in a new file `variables.auto.pkrvars.hcl`
Build image: `packer build -machine-readable -var-file variables.auto.pkrvars.hcl image.pkr.hcl | tee build.log`

## 2. Provision EC2 in a VPC using terraform
cd into `instances/`
Copy the AMI ID from packer build, update it in `variables.tf`
Provision infra: `terraform apply`


Everything from here onwards is handled in `instances/scripts/start.sh`

## 3. Run ansible script
Run post-provisioning configurations such as nginx SSL

## 4. Deploy application
Rerun the latest deploy job in github action

# Operational hours
Market data notification will run from:
* 8.15am - 9.15am, 3.30pm - 4.45pm in US timezone every day