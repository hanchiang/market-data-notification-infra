#! /bin/bash

set -e

DOMAIN=$1
ACTION=$2
TTL=$3

if [ -z "$DOMAIN" ]
then
    echo "domain is required. usage: <path/to/script> <domain>"
    exit 1
fi
if [ -z "$ACTION" ]
then
    echo "action is required. usage: <path/to/script> <domain>"
    exit 1
fi
if [ -z "$TTL" ]
then
    TTL=300
fi

source ./helper/ec2-helper.sh

if [ "$ACTION" == "UPSERT" ] || [ "$ACTION" == "CREATE" ]
then
    instance_info=$(get_instance_info)
    instance_ip_address=$(echo $instance_info | jq -r '.ip_address')
    instance_state=$(echo $instance_info | jq -r '.state')
    instance_id=$(echo $instance_info | jq -r .'id')
    ip_addresses=($instance_ip_address)
elif [ "$ACTION" == "DELETE" ]
then
    command=$(echo "aws route53 list-resource-record-sets --hosted-zone-id Z036374065L40GHHCTH5 | jq '.ResourceRecordSets[] | select (.Name | contains(\"$DOMAIN\")) | select(.Type == \"A\")'")
    record=$(eval $command)
    ip_addresses=($(echo $record | jq -r '.ResourceRecords[].Value'))
else
    echo "Unrecognised action $ACTION"
    exit 1
fi

echo "Updating route53 record for instance $instance_id, ip addresses $ip_addresses, action $ACTION, domain $DOMAIN"

#### Update route53 record set
for ip in "${ip_addresses[@]}"
do
    record_set_file="route53/change-record-set.json"
    record_set_template_file="route53/change-record-set.json.tpl"

    cat $record_set_template_file | sed "s~<INSTANCE_IP_ADDRESS>~$ip~" \
    | sed "s~<DOMAIN>~$DOMAIN~" | sed "s~<ACTION>~$ACTION~" | sed "s~<TTL>~$TTL~" > $record_set_file
    aws route53 change-resource-record-sets --hosted-zone-id Z036374065L40GHHCTH5 --change-batch file://$record_set_file > /dev/null

    rm $record_set_file
    echo "Updated route53 record for ip address $ip, action $ACTION, TTL $TTL"
done
