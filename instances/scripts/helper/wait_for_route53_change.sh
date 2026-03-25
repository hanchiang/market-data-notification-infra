#! /bin/bash

source ./helper/timer.sh

wait_for_route53_change () {
    change_id=$1

    if [ -z "$change_id" ]
    then
        echo "route53 change id is required"
        return 1
    fi

    echo "Waiting for route53 change $change_id to be INSYNC"

    local seconds_to_wait=180

    start=$(date +%s)
    time_elapsed=$(get_time_elapsed $start | tail -n 1)

    while [ "$time_elapsed" -lt "$seconds_to_wait" ];
    do
        change_status=$(aws route53 get-change --id "$change_id" | jq -r '.ChangeInfo.Status')

        if [ "$change_status" == "INSYNC" ]
        then
            echo "Route53 change $change_id is INSYNC"
            return 0
        fi

        echo "Route53 change $change_id status is $change_status. Waiting."
        sleep 10
        time_elapsed=$(get_time_elapsed $start | tail -n 1)
    done

    echo "Route53 change $change_id did not reach INSYNC after $seconds_to_wait seconds"
    return 1
}
