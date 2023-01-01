# https://docs.ansible.com/ansible/latest/collections/amazon/aws/aws_ec2_inventory.html
plugin: aws_ec2
regions: us-east-1
aws_access_key: AWS_ACCESS_KEY
aws_secret_key: AWS_SECRET_KEY
keyed_groups:
  - key: tags
    prefix: tag
  - key: tags.Name
    separator: ''