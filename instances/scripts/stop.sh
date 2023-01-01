#! /bin/bash

set -eu

dir=$(dirname $0)
cd $dir

source ./helper/ec2-helper.sh

instance_info=$(get_instance_info)
instance_state=$(echo $instance_info | jq -r '.state')
instance_ip_address=$(echo $instance_info | jq -r '.ip_address')
instance_id=$(echo $instance_info | jq -r .'id')

if [ "$instance_state" = "running" ]
then
    DOMAINS=("api.marketdata.yaphc.com" "go.yaphc.com")
    for domain in "${DOMAINS[@]}"
    do
        ./route53/update-ec2-route53.sh $domain "DELETE"
    done
    
    echo "Stopping ec2 $instance_id"
    aws ec2 stop-instances --instance-ids $instance_id > /dev/null
    printf "\n"
else
    echo "ec2 $instance_id is not running"
    exit 0
fi
