# https://docs.ansible.com/ansible/latest/collections/amazon/aws/aws_ec2_inventory.html
plugin: amazon.aws.aws_ec2
hostvars_prefix: aws_
regions:
  - AWS_REGION
keyed_groups:
  - key: aws_ec2_tags
    prefix: tag
  - key: aws_ec2_tags.Name
    separator: ''
include_filters:
  - tag:Name:
      - INSTANCE_TAG_NAME
