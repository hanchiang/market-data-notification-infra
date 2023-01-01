#! /bin/bash

set -e

# Get info of the instance that is most recently launched
get_instance_info () {
    instance_info=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=market_data_notification" --query 'Reservations[].Instances[].{ip_address:PublicIpAddress,state:State.Name,id:InstanceId,launch_time:LaunchTime,tags:Tags}' --output json | jq '[sort_by(.launch_time) | reverse[]][0]')
    echo $instance_info
}