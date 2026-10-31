#! /bin/bash

set -euo pipefail

# Readiness (Goal 8): wait until an instance's Session Manager agent reports Online.
# With --since <epoch seconds>, the last ping must also be later than that time, because
# after a short stop and start the service can still show the previous boot's Online.
# Pass --since only when the caller started the instance; a running instance needs Online
# alone, and requiring a fresh ping there would wait on the agent's five-minute heartbeat.
#
# usage: wait_for_ssm_online.sh <instance-id> [--since <epoch>] [--timeout <s>] [--interval <s>]
# Exit 0 ready, 1 timed out, 2 bad usage. An AWS error (access denied) exits at once.

# 300 s is two to three times a normal registration. Revisit if an observed registration
# takes more than half of it.
DEFAULT_TIMEOUT_SECONDS=300
DEFAULT_INTERVAL_SECONDS=10

usage () {
    echo "usage: $(basename "$0") <instance-id> [--since <epoch seconds>] [--timeout <seconds>] [--interval <seconds>]" >&2
    exit 2
}

instance_id=${1:-}
[ -n "$instance_id" ] || usage
case "$instance_id" in -*) usage ;; esac
shift
since=
timeout_seconds=$DEFAULT_TIMEOUT_SECONDS
interval_seconds=$DEFAULT_INTERVAL_SECONDS
while [ $# -gt 0 ]
do
    case "$1" in
        --since) since=${2:-}; shift 2 || usage ;;
        --timeout) timeout_seconds=${2:-}; shift 2 || usage ;;
        --interval) interval_seconds=${2:-}; shift 2 || usage ;;
        *) usage ;;
    esac
done
for number in "$timeout_seconds" "$interval_seconds" ${since:+"$since"}
do
    [[ "$number" =~ ^[0-9]+$ ]] || usage
done

# LastPingDateTime is an ISO 8601 string from AWS CLI v2 and epoch seconds from v1.
to_epoch () {
    local value="$1"
    if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]
    then
        echo "${value%.*}"
    else
        date -u -d "$value" +%s
    fi
}

deadline=$(( $(date -u +%s) + timeout_seconds ))
while true
do
    info=$(aws ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$instance_id" --output json)
    ping_status=$(jq -r '.InstanceInformationList[0].PingStatus // ""' <<< "$info")
    last_ping=$(jq -r '.InstanceInformationList[0].LastPingDateTime // "" | tostring' <<< "$info")

    if [ "$ping_status" = "Online" ]
    then
        if [ -z "$since" ]
        then
            echo "Session Manager agent on $instance_id is Online"
            exit 0
        fi
        if [ -n "$last_ping" ] && [ "$(to_epoch "$last_ping")" -gt "$since" ]
        then
            echo "Session Manager agent on $instance_id is Online, last ping $last_ping"
            exit 0
        fi
        echo "Agent on $instance_id shows Online from before the start (last ping $last_ping); waiting"
    else
        echo "Agent on $instance_id is ${ping_status:-not registered}; waiting"
    fi

    if [ "$(date -u +%s)" -ge "$deadline" ]
    then
        echo "Session Manager agent on $instance_id not Online after $timeout_seconds seconds" >&2
        exit 1
    fi
    sleep "$interval_seconds"
done
