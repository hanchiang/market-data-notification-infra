#! /bin/bash

set -eu

# Stop the EC2 instance and remove the public Route53 record for the service domain.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
START_ENV_FILE=${START_ENV_FILE:-"$SCRIPT_DIR/start.local.env"}

if [ -f "$START_ENV_FILE" ]
then
    # shellcheck disable=SC1090
    source "$START_ENV_FILE"
fi

DOMAIN=${DOMAIN:-}
ROUTE53_HOSTED_ZONE_ID=${ROUTE53_HOSTED_ZONE_ID:-}

source "$SCRIPT_DIR/helper/ec2-helper.sh"

if [ -z "$DOMAIN" ]
then
    echo "Missing required environment variable: DOMAIN" >&2
    exit 1
fi

if [ -z "$ROUTE53_HOSTED_ZONE_ID" ]
then
    echo "Missing required environment variable: ROUTE53_HOSTED_ZONE_ID" >&2
    exit 1
fi

export ROUTE53_HOSTED_ZONE_ID

instance_info=$(get_instance_info)
instance_state=$(echo "$instance_info" | jq -r '.state')
instance_id=$(echo "$instance_info" | jq -r '.id')

if [ "$instance_state" = "running" ]
then
    DOMAINS=("$DOMAIN")
    for domain in "${DOMAINS[@]}"
    do
        "$SCRIPT_DIR/route53/update-ec2-route53.sh" "$domain" "DELETE"
    done
    
    echo "Stopping ec2 $instance_id"
    aws ec2 stop-instances --instance-ids "$instance_id" > /dev/null
    printf "\n"
else
    echo "ec2 $instance_id is not running"
    exit 0
fi
