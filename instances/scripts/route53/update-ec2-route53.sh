#! /bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DOMAIN=${1:-}
ACTION=${2:-}
TTL=${3:-}
ROUTE53_HOSTED_ZONE_ID=${ROUTE53_HOSTED_ZONE_ID:-}

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
if [ -z "$ROUTE53_HOSTED_ZONE_ID" ]
then
    echo "ROUTE53_HOSTED_ZONE_ID is required" >&2
    exit 1
fi

source "$SCRIPT_DIR/../helper/ec2-helper.sh"

normalize_domain() {
    local domain="$1"
    if [[ "$domain" == *. ]]
    then
        printf '%s\n' "$domain"
    else
        printf '%s.\n' "$domain"
    fi
}

get_existing_a_record() {
    local normalized_domain="$1"

    aws route53 list-resource-record-sets \
        --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" \
        --start-record-name "$normalized_domain" \
        --start-record-type A \
        --max-items 1 | \
        jq --arg name "$normalized_domain" \
           '.ResourceRecordSets[0] | select(.Name == $name and .Type == "A")'
}

record_matches_desired_state() {
    local record_json="$1"
    local desired_ttl="$2"

    if [ -z "$record_json" ] || [ "$record_json" = "null" ]
    then
        return 1
    fi

    local existing_ttl
    existing_ttl=$(echo "$record_json" | jq -r '.TTL')
    if [ "$existing_ttl" != "$desired_ttl" ]
    then
        return 1
    fi

    local existing_values desired_values
    existing_values=$(echo "$record_json" | jq -r '.ResourceRecords[].Value' | sort)
    desired_values=$(printf '%s\n' "${ip_addresses[@]}" | sort)

    if [ "$existing_values" != "$desired_values" ]
    then
        return 1
    fi

    return 0
}

instance_id=""
normalized_domain=$(normalize_domain "$DOMAIN")

if [ "$ACTION" == "UPSERT" ] || [ "$ACTION" == "CREATE" ]
then
    instance_info=$(get_instance_info)
    instance_ip_address=$(echo "$instance_info" | jq -r '.ip_address')
    instance_id=$(echo "$instance_info" | jq -r '.id')
    ip_addresses=("$instance_ip_address")
elif [ "$ACTION" == "DELETE" ]
then
    record=$(get_existing_a_record "$normalized_domain")
    if [ -z "$record" ]
    then
        echo "No existing route53 A record found for domain $DOMAIN; nothing to delete" >&2
        exit 0
    fi
    mapfile -t ip_addresses < <(echo "$record" | jq -r '.ResourceRecords[].Value')
else
    echo "Unrecognised action $ACTION"
    exit 1
fi

if [ "$ACTION" == "UPSERT" ]
then
    existing_record=$(get_existing_a_record "$normalized_domain")
    if record_matches_desired_state "$existing_record" "$TTL"
    then
        echo "Route53 A record for $DOMAIN already points at ${ip_addresses[*]} with TTL $TTL; skipping update" >&2
        exit 0
    fi
fi

change_ids=()

if [ -n "$instance_id" ]
then
    echo "Updating route53 record for instance $instance_id, ip addresses ${ip_addresses[*]}, action $ACTION, domain $DOMAIN" >&2
else
    echo "Updating route53 record for ip addresses ${ip_addresses[*]}, action $ACTION, domain $DOMAIN" >&2
fi

#### Update route53 record set
for ip in "${ip_addresses[@]}"
do
    record_set_file="route53/change-record-set.json"
    record_set_template_file="route53/change-record-set.json.tpl"

    sed "s~<INSTANCE_IP_ADDRESS>~$ip~" "$record_set_template_file" \
    | sed "s~<DOMAIN>~$DOMAIN~" | sed "s~<ACTION>~$ACTION~" | sed "s~<TTL>~$TTL~" > "$record_set_file"
    change_id=$(aws route53 change-resource-record-sets --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" --change-batch file://"$record_set_file" | jq -r '.ChangeInfo.Id')

    rm "$record_set_file"
    echo "Updated route53 record for ip address $ip, action $ACTION, TTL $TTL, change $change_id" >&2
    change_ids+=("$change_id")
done

printf '%s\n' "${change_ids[@]}"
