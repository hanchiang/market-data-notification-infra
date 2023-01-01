#! /bin/bash
set -eu

dir=$(dirname $0)
cd $dir

source ./helper/ec2-helper.sh
source ./helper/wait_for_dns_propagation.sh
source ./helper/timer.sh

GITHUB_TOKEN=$1
SSH_USER=$2
SSH_PRIVATE_KEY_PATH=$3

usage () {
    echo "Invalid $1. usage: <path/to/script> <github token> <ssh user> <ssh private key path>"
    exit 1
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


#### Start EC2

wait_for_ec2_stop () {
    instance_info=$(get_instance_info)
    echo $instance_info
    instance_ip_address=$(echo $instance_info | jq -r '.ip_address')
    instance_state=$(echo $instance_info | jq -r '.state')
    instance_id=$(echo $instance_info | jq -r .'id')
    
    if [ "$instance_state" = "running" ] || [ "$instance_state" = "terminated" ] || [ "$instance_state" = "shutting-down" ]
    then
        echo "Instance cannot be started because it is either running, terminated or going to be terminated"
        return 0
    elif [ "$instance_state" == "stopped" ] 
    then
        echo "Instance is already stopped"
        return 0
    else
        local seconds_to_wait=120

        start=$(date +%s)
        time_elapsed=$(get_time_elapsed $start | tail -n 1)

        while [ "$instance_state" != "stopped" ] && [ "$time_elapsed" -lt "$seconds_to_wait" ];
        do
            echo "Waiting for instance $instance_id to be stopped"
            sleep 10
            instance_info=$(get_instance_info)
            instance_state=$(echo $instance_info | jq -r '.state')

            if [ "$instance_state" == "stopped" ]
            then
                echo "Instance $instance_id has stopped"
                printf "\n"
                return 0
            fi
            time_elapsed=$(get_time_elapsed $start | tail -n 1)
        done
        echo "Instance $instance_id did not stop after $seconds_to_wait seconds"
    fi
    printf "\n"
}


start_ec2() {
    instance_info=$(get_instance_info)
    instance_state=$(echo $instance_info | jq -r '.state')
    instance_id=$(echo $instance_info | jq -r .'id')
    instance_ip_address=$(echo $instance_info | jq -r '.ip_address')

    if [ "$instance_state" == "running" ]
    then
        echo "Instance $instance_id is already running. Ip address $instance_ip_address"
        printf "\n"
        return 0
    fi

    local seconds_to_wait=120

    start=$(date +%s)
    time_elapsed=$(get_time_elapsed $start | tail -n 1)

    echo "Starting ec2 $instance_id"
    aws ec2 start-instances --instance-ids $instance_id > /dev/null

    while [ "$instance_state" != "running" ] && [ "$time_elapsed" -lt "$seconds_to_wait" ];
    do
        echo "Waiting for instance $instance_id to be running"
        sleep 10

        instance_info=$(get_instance_info)
        instance_state=$(echo $instance_info | jq -r '.state')
        instance_id=$(echo $instance_info | jq -r .'id')
        instance_ip_address=$(echo $instance_info | jq -r '.ip_address')

        if [ "$instance_state" == "running" ]
        then
            echo "Instance $instance_id is running. Ip address $instance_ip_address"
            printf "\n"
            return 0
        fi
        time_elapsed=$(get_time_elapsed $start | tail -n 1)
    done
    echo "Instance $instance_id is not running after $seconds_to_wait seconds"
    printf "\n"
}

get_latest_github_workflow_jobs_url () {
    echo "Trigger deploy on github actions"
    echo "Getting the latest github actions workflow"

    local latest_workflow
    local workflow_id
    local workflow_url
    local workflow_created_at
    local commit_message
    local jobs_url

    latest_workflow=$(curl -H "Accept: application/vnd.github+json" -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/hanchiang/market-data-notification/actions/runs\?branch=master\&per_page=100 | jq '[.workflow_runs[] | select(.name | ascii_downcase | contains("build and deploy"))][0]')
    if [ "$?" -ne 0 ]
    then
        return 1
    fi

    workflow_id=$(echo $latest_workflow | jq '.id')
    workflow_url=$(echo $latest_workflow | jq -r '.url')
    workflow_created_at=$(echo $latest_workflow | jq -r '.created_at')
    commit_message=$(echo $latest_workflow | jq -r '.head_commit.message')
    jobs_url=$(echo $latest_workflow | jq -r '.jobs_url')

    echo "workflow url: $workflow_url, created at: $workflow_created_at"
    echo $jobs_url
}


# Start EC2
wait_for_ec2_stop
start_ec2

# Update route53 record
DOMAINS=("api.marketdata.yaphc.com")
for domain in "${DOMAINS[@]}"
do
    ./route53/update-ec2-route53.sh $domain "UPSERT"
    wait_for_dns_propagation $domain $instance_ip_address
    printf "\n"
done

# Configure EC2
../ansible/start.sh $SSH_USER $SSH_PRIVATE_KEY_PATH 

# Re-run deploy workflow
# deploy_workflow=$(curl  -H "Accept: application/vnd.github+json" -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/hanchiang/market-data-notification/actions/workflows |  jq '.workflows[] | select(.state == "active" and select(.name | ascii_downcase | contains("build and deploy")))')
# printf "\n"

# workflow_id=$(echo $deploy_workflow | jq -r .id)
# curl -X POST  -H "Accept: application/vnd.github+json" -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/hanchiang/market-data-notification/actions/workflows/$workflow_id/dispatches \
#  -d '{"ref":"master"}'
# printf "\n"

echo "Script completed in $SECONDS seconds"