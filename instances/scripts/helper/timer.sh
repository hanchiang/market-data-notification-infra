#! /bin/bash

set -e

get_time_elapsed () {
    start_time_in_seconds=$1

    if [ -z $start_time_in_seconds ]
    then
        echo "usage: get_time_elapsed <start time in seconds>"
        return 1
    fi

    now=$(date +%s)
    time_elapsed=$(($now - $start_time_in_seconds))
    echo "$time_elapsed seconds has passed"
    echo $time_elapsed
}