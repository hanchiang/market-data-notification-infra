#! /bin/bash
set -euo pipefail

# Full operator start path: ensure the instance is running, reconcile DNS and host config,
# then dispatch the backend deploy workflow once infra is ready.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]
then
    echo "Run this script directly, do not source it." >&2
    return 1 2>/dev/null || exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source "$SCRIPT_DIR/helper/ec2-helper.sh"
source "$SCRIPT_DIR/helper/wait_for_route53_change.sh"
source "$SCRIPT_DIR/helper/timer.sh"

GITHUB_TOKEN=${1:-}
SSH_USER=${2:-}
SSH_PRIVATE_KEY_PATH=${3:-}
ANSIBLE_DIR="$(cd ../ansible && pwd)"
ANSIBLE_LOCAL_TEMP_DIR=${ANSIBLE_LOCAL_TEMP:-/tmp/ansible-local}
ANSIBLE_CONFIG_PATH="$ANSIBLE_DIR/ansible.cfg"
ANSIBLE_INVENTORY_PATH="$ANSIBLE_DIR/aws_ec2.yml"
ANSIBLE_VARS_PATH="$ANSIBLE_DIR/vars.yml"
START_ENV_FILE=${START_ENV_FILE:-"$SCRIPT_DIR/start.local.env"}

if [ -f "$START_ENV_FILE" ];
then
    # shellcheck disable=SC1090
    source "$START_ENV_FILE"
fi

AWS_REGION=${AWS_REGION:-}
DOMAIN=${DOMAIN:-}
ADMIN_EMAIL=${ADMIN_EMAIL:-}
LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY=${LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY:-}
INSTANCE_TAG_NAME=${INSTANCE_TAG_NAME:-}
ROUTE53_HOSTED_ZONE_ID=${ROUTE53_HOSTED_ZONE_ID:-}

usage () {
    echo "Invalid $1. usage: <path/to/script> <github token> <ssh user> <ssh private key path>"
    exit 1
}

require_cmd() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1
    then
        echo "Missing required command: $name" >&2
        exit 1
    fi
}

require_env() {
    local name="$1"
    local value="$2"
    if [ -z "$value" ]
    then
        echo "Missing required environment variable: $name" >&2
        exit 1
    fi
}

if [ -z "$GITHUB_TOKEN"  ];
then
    usage "github token"
fi

if [ -z "$SSH_USER"  ];
then
    usage "ssh user"
fi

if [ -z "$SSH_PRIVATE_KEY_PATH"  ];
then
    usage "ssh private key path"
fi

require_cmd ansible-playbook
require_cmd ansible-doc
require_env ADMIN_EMAIL "$ADMIN_EMAIL"
require_env AWS_REGION "$AWS_REGION"
require_env DOMAIN "$DOMAIN"
require_env INSTANCE_TAG_NAME "$INSTANCE_TAG_NAME"
require_env ROUTE53_HOSTED_ZONE_ID "$ROUTE53_HOSTED_ZONE_ID"

export ROUTE53_HOSTED_ZONE_ID

mkdir -p "$ANSIBLE_LOCAL_TEMP_DIR"

cat << EOF > "$ANSIBLE_CONFIG_PATH"
[inventory]
enable_plugins = host_list, script, auto, yaml, ini, toml, amazon.aws.aws_ec2

[defaults]
host_key_checking = False
local_tmp = $ANSIBLE_LOCAL_TEMP_DIR
EOF

if ! ANSIBLE_CONFIG="$ANSIBLE_CONFIG_PATH" ANSIBLE_LOCAL_TEMP="$ANSIBLE_LOCAL_TEMP_DIR" ansible-doc -t inventory -l 2>/dev/null | grep -Eq '^amazon\.aws\.aws_ec2([[:space:]]|$)'
then
    echo "Missing Ansible inventory plugin amazon.aws.aws_ec2. Install it with: ansible-galaxy collection install amazon.aws" >&2
    exit 1
fi

cat << EOF > "$ANSIBLE_INVENTORY_PATH"
plugin: amazon.aws.aws_ec2
hostvars_prefix: aws_
regions:
  - $AWS_REGION
keyed_groups:
  - key: aws_ec2_tags
    prefix: tag
  - key: aws_ec2_tags.Name
    separator: ''
include_filters:
  - tag:Name:
      - $INSTANCE_TAG_NAME
EOF

cat << EOF > "$ANSIBLE_VARS_PATH"
USER: $SSH_USER
DOMAIN: $DOMAIN
DOMAINS:
  - $DOMAIN
ADMIN_EMAIL: $ADMIN_EMAIL
ansible_python_interpreter: /usr/bin/python3
LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY: "$LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY"
EOF

cleanup_ansible_inputs() {
    rm -f "$ANSIBLE_CONFIG_PATH" "$ANSIBLE_INVENTORY_PATH" "$ANSIBLE_VARS_PATH"
}

trap cleanup_ansible_inputs EXIT


#### Start EC2

wait_for_ec2_stop () {
    instance_info=$(get_instance_info)
    echo "$instance_info"
    instance_ip_address=$(echo "$instance_info" | jq -r '.ip_address')
    instance_state=$(echo "$instance_info" | jq -r '.state')
    instance_id=$(echo "$instance_info" | jq -r '.id')
    
    if [ "$instance_state" = "running" ]
    then
        echo "Instance $instance_id is already running. Continuing with reconciliation."
        return 0
    elif [ "$instance_state" = "terminated" ] || [ "$instance_state" = "shutting-down" ]
    then
        echo "Instance $instance_id cannot be started because it is $instance_state"
        return 1
    elif [ "$instance_state" == "stopped" ] 
    then
        echo "Instance is already stopped"
        return 0
    else
        local seconds_to_wait=180

        start=$(date +%s)
        time_elapsed=$(get_time_elapsed "$start" | tail -n 1)

        while [ "$instance_state" != "stopped" ] && [ "$time_elapsed" -lt "$seconds_to_wait" ];
        do
            echo "Waiting for instance $instance_id to be stopped"
            sleep 10
            instance_info=$(get_instance_info)
            instance_state=$(echo "$instance_info" | jq -r '.state')

            if [ "$instance_state" == "stopped" ]
            then
                echo "Instance $instance_id has stopped"
                printf "\n"
                return 0
            fi
            time_elapsed=$(get_time_elapsed "$start" | tail -n 1)
        done
        echo "Instance $instance_id did not stop after $seconds_to_wait seconds"
        return 1
    fi
    printf "\n"
}


start_ec2() {
    instance_info=$(get_instance_info)
    instance_state=$(echo "$instance_info" | jq -r '.state')
    instance_id=$(echo "$instance_info" | jq -r '.id')
    instance_ip_address=$(echo "$instance_info" | jq -r '.ip_address')

    if [ "$instance_state" == "running" ]
    then
        echo "Instance $instance_id is already running. Ip address $instance_ip_address"
        printf "\n"
        return 0
    fi

    local seconds_to_wait=180

    start=$(date +%s)
    time_elapsed=$(get_time_elapsed "$start" | tail -n 1)

    echo "Starting ec2 $instance_id"
    aws ec2 start-instances --instance-ids "$instance_id" > /dev/null

    while [ "$instance_state" != "running" ] && [ "$time_elapsed" -lt "$seconds_to_wait" ];
    do
        echo "Waiting for instance $instance_id to be running"
        sleep 10

        instance_info=$(get_instance_info)
        instance_state=$(echo "$instance_info" | jq -r '.state')
        instance_id=$(echo "$instance_info" | jq -r '.id')
        instance_ip_address=$(echo "$instance_info" | jq -r '.ip_address')

        if [ "$instance_state" == "running" ]
        then
            echo "Instance $instance_id is running. Ip address $instance_ip_address"
            printf "\n"
            return 0
        fi
        time_elapsed=$(get_time_elapsed "$start" | tail -n 1)
    done
    echo "Instance $instance_id is not running after $seconds_to_wait seconds"
    printf "\n"
    return 1
}

get_latest_successful_ci_sha () {
    echo "Getting latest successful master CI run"

    local latest_ci_run
    local image_sha

    if ! latest_ci_run=$(curl -fsSL -H "Accept: application/vnd.github+json" -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/hanchiang/market-data-notification/actions/runs?branch=master&status=completed&per_page=100" | jq '[.workflow_runs[] | select(.name | ascii_downcase | contains("test and build")) | select(.conclusion == "success")][0]')
    then
        return 1
    fi

    image_sha=$(echo "$latest_ci_run" | jq -r '.head_sha')
    if [ -z "$image_sha" ] || [ "$image_sha" = "null" ]
    then
        echo "Could not determine latest successful master CI SHA"
        return 1
    fi

    echo "$image_sha"
}


# Start EC2 first, then hand off the application rollout to the backend deploy workflow.
wait_for_ec2_stop
start_ec2

# Update route53 record
DOMAINS=("api.marketdata.yaphc.com")
for domain in "${DOMAINS[@]}"
do
    change_ids=$(./route53/update-ec2-route53.sh "$domain" "UPSERT")
    while IFS= read -r change_id
    do
        if [ -n "$change_id" ]
        then
            wait_for_route53_change "$change_id"
        fi
    done <<< "$change_ids"
    printf "\n"
done

sleep 10

# Configure EC2
ANSIBLE_CONFIG="$ANSIBLE_CONFIG_PATH" \
ANSIBLE_LOCAL_TEMP="$ANSIBLE_LOCAL_TEMP_DIR" \
../ansible/start.sh "$SSH_USER" "$SSH_PRIVATE_KEY_PATH"

# Re-run deploy workflow
deploy_image_sha=$(get_latest_successful_ci_sha | tail -n 1)
if [ -z "$deploy_image_sha" ]
then
    echo "No deploy image SHA resolved from CI"
    exit 1
fi
deploy_workflow_json=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/hanchiang/market-data-notification/actions/workflows")
deploy_workflow=$(jq '.workflows[] | select(.state == "active" and (.name | ascii_downcase | contains("build and deploy")))' <<< "$deploy_workflow_json")
printf "\n"

workflow_id=$(echo "$deploy_workflow" | jq -r '.id')
deploy_payload=$(jq -n --arg image_sha "$deploy_image_sha" '{ref:"master",inputs:{image_sha:$image_sha,allow_unverified_image:"true"}}')
curl -fsSL \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/hanchiang/market-data-notification/actions/workflows/$workflow_id/dispatches" \
    -d "$deploy_payload"
printf "\n"

echo "Script completed in $SECONDS seconds"
