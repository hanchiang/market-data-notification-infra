#! /bin/bash
set -euo pipefail

# Full operator start path: ensure the instance is running, reconcile DNS and host config,
# then dispatch the backend deploy workflow once infra is ready.
#
# Inputs come from the environment, never arguments: a token in argv shows in the
# process list (Goal 9). SSH reaches the host over Session Manager with the host key
# pinned under a stable alias, through a private SSH config this script writes.
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
source "$SCRIPT_DIR/helper/github_api.sh"

ANSIBLE_DIR="$(cd ../ansible && pwd)"
ANSIBLE_LOCAL_TEMP_DIR=${ANSIBLE_LOCAL_TEMP:-/tmp/ansible-local}
ANSIBLE_CONFIG_PATH="$ANSIBLE_DIR/ansible.cfg"
ANSIBLE_VARS_PATH="$ANSIBLE_DIR/vars.yml"
START_ENV_FILE=${START_ENV_FILE:-"$SCRIPT_DIR/start.local.env"}
SKIP_DEPLOY=false
# The known_hosts name every consumer pins the host key under, so the pin survives the
# instance id changing on a rebuild.
HOST_KEY_ALIAS=market-data-notification-production
SSH_SESSION_DOCUMENT=MarketDataNotification-SSH22
# SSH connect timeout, seconds. Under a ProxyCommand it bounds the whole Session Manager
# handshake. Every host consumer uses the same value; raise them together (the workspace
# runbook's Timeouts list names each one, and a workspace test checks they agree).
SSH_CONNECT_TIMEOUT_SECONDS=23
# ansible/start.sh: runtime playbooks passed, a security playbook failed.
SECURITY_PLAYBOOK_FAILED=75

usage () {
    cat >&2 <<'EOF'
usage:
  ./scripts/start.sh [--skip-deploy]

Inputs come from the environment (or start.local.env), never from arguments:
  MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN  GitHub token for the deploy dispatch; not needed with --skip-deploy
  SSH_USER                               login user on the host
  SSH_PRIVATE_KEY_PATH                   private key file for SSH_USER
  SSH_KNOWN_HOSTS_FILE                   known_hosts holding the host key under market-data-notification-production
EOF
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

# Any positional argument is an old caller, which would pass the token in argv. It is
# stopped before anything runs, not half-honoured.
parse_args() {
    while [ $# -gt 0 ]
    do
        case "$1" in
            --skip-deploy)
                SKIP_DEPLOY=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            --*)
                echo "Unknown flag: $1" >&2
                usage
                ;;
            *)
                echo "start.sh takes no positional arguments; set MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN, SSH_USER, SSH_PRIVATE_KEY_PATH and SSH_KNOWN_HOSTS_FILE in the environment" >&2
                usage
                ;;
        esac
    done
}

parse_args "$@"

if [ -f "$START_ENV_FILE" ];
then
    # shellcheck disable=SC1090
    source "$START_ENV_FILE"
fi

AWS_REGION=${AWS_REGION:-}
DOMAIN=${DOMAIN:-}
ADMIN_EMAIL=${ADMIN_EMAIL:-}
LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY=${LETSENCRYPT_BACKUP_AGE_PUBLIC_KEY:-}
ROUTE53_HOSTED_ZONE_ID=${ROUTE53_HOSTED_ZONE_ID:-}
MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN=${MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN:-}
SSH_USER=${SSH_USER:-}
SSH_PRIVATE_KEY_PATH=${SSH_PRIVATE_KEY_PATH:-}
SSH_KNOWN_HOSTS_FILE=${SSH_KNOWN_HOSTS_FILE:-}

export ROUTE53_HOSTED_ZONE_ID

require_cmd ansible-playbook
require_cmd aws
require_cmd session-manager-plugin
require_cmd jq
require_cmd ssh-keygen
require_env ADMIN_EMAIL "$ADMIN_EMAIL"
require_env AWS_REGION "$AWS_REGION"
require_env DOMAIN "$DOMAIN"
require_env ROUTE53_HOSTED_ZONE_ID "$ROUTE53_HOSTED_ZONE_ID"
require_env SSH_USER "$SSH_USER"
require_env SSH_PRIVATE_KEY_PATH "$SSH_PRIVATE_KEY_PATH"
require_env SSH_KNOWN_HOSTS_FILE "$SSH_KNOWN_HOSTS_FILE"

if [ "$SKIP_DEPLOY" != "true" ]
then
    require_env MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN "$MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN"
fi

# Fail before touching AWS when the pin is missing: every connection would refuse anyway.
if ! ssh-keygen -F "$HOST_KEY_ALIAS" -f "$SSH_KNOWN_HOSTS_FILE" > /dev/null
then
    echo "$SSH_KNOWN_HOSTS_FILE holds no host key for $HOST_KEY_ALIAS" >&2
    exit 1
fi

mkdir -p "$ANSIBLE_LOCAL_TEMP_DIR"
SSH_CONFIG_DIR=$(mktemp -d)
SSH_CONFIG_PATH="$SSH_CONFIG_DIR/ssh_config"

# Without ControlPersist every Ansible task opens its own Session Manager session:
# seconds each, and a CloudTrail record per task.
cat << EOF > "$ANSIBLE_CONFIG_PATH"
[defaults]
host_key_checking = True
local_tmp = $ANSIBLE_LOCAL_TEMP_DIR
# Ansible passes this to ssh as ConnectTimeout; its default is 10.
timeout = $SSH_CONNECT_TIMEOUT_SECONDS

[ssh_connection]
ssh_args = -F $SSH_CONFIG_PATH -o ControlMaster=auto -o ControlPersist=60s
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
    rm -f "$ANSIBLE_CONFIG_PATH" "$ANSIBLE_VARS_PATH"
    rm -rf "$SSH_CONFIG_DIR"
}

# The one SSH entry shape every consumer uses, for the instance this
# run just started or found running. The alias, not the instance id, keys the pin.
write_ssh_config () {
    local aws_bin
    aws_bin=$(command -v aws)
    cat << EOF > "$SSH_CONFIG_PATH"
Host production
  HostName $instance_id
  User $SSH_USER
  IdentityFile "$SSH_PRIVATE_KEY_PATH"
  IdentitiesOnly yes
  HostKeyAlias $HOST_KEY_ALIAS
  StrictHostKeyChecking yes
  UserKnownHostsFile "$SSH_KNOWN_HOSTS_FILE"
  ServerAliveInterval 30
  ProxyCommand $aws_bin ssm start-session --region $AWS_REGION --target %h --document-name $SSH_SESSION_DOCUMENT
EOF
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
    EC2_STARTED_AT=$(date -u +%s)
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

    if ! latest_ci_run=$(github_api "https://api.github.com/repos/hanchiang/market-data-notification/actions/runs?branch=master&status=completed&per_page=100" | jq '[.workflow_runs[] | select(.name | ascii_downcase | contains("test and build")) | select(.conclusion == "success")][0]')
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
EC2_STARTED_AT=
wait_for_ec2_stop
start_ec2

# Update route53 record
DOMAINS=("$DOMAIN")
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

# Readiness is the agent reporting Online (Goal 8). The start time goes in only when this
# run started the instance: then the previous boot's stale Online must not count.
wait_args=("$instance_id")
if [ -n "$EC2_STARTED_AT" ]
then
    wait_args+=(--since "$EC2_STARTED_AT")
fi
./helper/wait_for_ssm_online.sh "${wait_args[@]}"

write_ssh_config

# Configure EC2
ansible_rc=0
ANSIBLE_CONFIG="$ANSIBLE_CONFIG_PATH" \
ANSIBLE_LOCAL_TEMP="$ANSIBLE_LOCAL_TEMP_DIR" \
../ansible/start.sh "$SSH_USER" "$SSH_PRIVATE_KEY_PATH" || ansible_rc=$?
if [ "$ansible_rc" -ne 0 ] && [ "$ansible_rc" -ne "$SECURITY_PLAYBOOK_FAILED" ]
then
    exit "$ansible_rc"
fi

# The service comes up first; a failed security playbook then fails the run so it alerts.
finish () {
    echo "Script completed in $SECONDS seconds"
    if [ "$ansible_rc" -eq "$SECURITY_PLAYBOOK_FAILED" ]
    then
        echo "A security playbook (agent floor or SSH login-line push) failed; see the Ansible output above" >&2
        exit 1
    fi
    exit 0
}

# Re-run deploy workflow unless explicitly skipped for host-only start or recovery.
if [ "$SKIP_DEPLOY" = "true" ]
then
    echo "Skipping backend deploy workflow dispatch because --skip-deploy was set"
    finish
fi

deploy_image_sha=$(get_latest_successful_ci_sha | tail -n 1)
if [ -z "$deploy_image_sha" ]
then
    echo "No deploy image SHA resolved from CI"
    exit 1
fi
deploy_workflow_json=$(github_api "https://api.github.com/repos/hanchiang/market-data-notification/actions/workflows")
deploy_workflow=$(jq '.workflows[] | select(.state == "active" and (.name | ascii_downcase | contains("build and deploy")))' <<< "$deploy_workflow_json")
printf "\n"

workflow_id=$(echo "$deploy_workflow" | jq -r '.id')
deploy_payload=$(jq -n --arg image_sha "$deploy_image_sha" '{ref:"master",inputs:{image_sha:$image_sha,allow_unverified_image:"true"}}')
github_api \
    -X POST \
    "https://api.github.com/repos/hanchiang/market-data-notification/actions/workflows/$workflow_id/dispatches" \
    -d "$deploy_payload"
printf "\n"

finish
