# https://docs.ansible.com/ansible/latest/collections/amazon/aws/aws_ec2_inventory.html
plugin: amazon.aws.aws_ec2
regions:
  - AWS_REGION
keyed_groups:
  - key: ec2_tags
    prefix: tag
  - key: ec2_tags.Name
    separator: ''
include_filters:
  - tag:Name:
      - INSTANCE_TAG_NAME
