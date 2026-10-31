#! /bin/bash

set -euo pipefail

# Two out-of-band checks no tracked-file check can see, run on every start-workflow firing:
#   1. any port 22 rule on the host's security group, such as a forgotten break-glass rule;
#   2. the SSH login-line push silent for 48 hours. AWS/Logs publishes IncomingLogEvents
#      only when events arrive, so silence is an EMPTY Datapoints list, counted as zero.
# Either one alerts the dev chat and exits 1. It reads a metric, never log content.
#
# --allow-terraform-public-22 is phase 1 only: it tolerates the one rule main.tf still
# declares (tcp 22 from 0.0.0.0/0, no description). The phase 2 commit that deletes that
# ingress block deletes this flag from the workflow too. A break-glass rule carries a
# description and the operator's block, so it still alerts.

SECURITY_GROUP_NAME=${HOST_ACCESS_SECURITY_GROUP_NAME:-sg_22_80_443}
LOG_GROUP=${HOST_ACCESS_LOG_GROUP:-/market-data-notification/sshd}
SILENCE_HOURS=${HOST_ACCESS_SILENCE_HOURS:-48}
allow_terraform_rule=0

for arg in "$@"
do
    case "$arg" in
        --allow-terraform-public-22) allow_terraform_rule=1 ;;
        *) echo "usage: $(basename "$0") [--allow-terraform-public-22]" >&2; exit 2 ;;
    esac
done

problems=()

groups=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" --output json)
if [ "$(jq '.SecurityGroups | length' <<< "$groups")" -eq 0 ]
then
    problems+=("security group $SECURITY_GROUP_NAME not found")
else
    # One row per source on any rule whose port range covers 22 (protocol -1 covers all).
    open_sources=$(jq --argjson allow "$allow_terraform_rule" '
        [ .SecurityGroups[].IpPermissions[]
          | select(.IpProtocol == "-1"
                   or ((.IpProtocol == "tcp" or .IpProtocol == "6")
                       and (.FromPort // 0) <= 22 and (.ToPort // 65535) >= 22))
          | . as $rule
          | ( [(.IpRanges // [])[] | {source: .CidrIp, description: (.Description // "")}]
            + [(.Ipv6Ranges // [])[] | {source: .CidrIpv6, description: (.Description // "")}]
            + [(.PrefixListIds // [])[] | {source: .PrefixListId, description: (.Description // "")}]
            + [(.UserIdGroupPairs // [])[] | {source: .GroupId, description: (.Description // "")}] )[]
          | . + {protocol: $rule.IpProtocol, from: $rule.FromPort, to: $rule.ToPort} ]
        | map(select(($allow == 1 and .protocol == "tcp" and .from == 22 and .to == 22
                      and .source == "0.0.0.0/0" and .description == "") | not))
        | length' <<< "$groups")
    if [ "$open_sources" -gt 0 ]
    then
        problems+=("port 22 is open on $SECURITY_GROUP_NAME to $open_sources source(s); remove any break-glass rule")
    fi
fi

end_epoch=$(date -u +%s)
start_epoch=$(( end_epoch - SILENCE_HOURS * 3600 ))
metric=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Logs --metric-name IncomingLogEvents \
    --dimensions "Name=LogGroupName,Value=$LOG_GROUP" \
    --start-time "$(date -u -d "@$start_epoch" +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u -d "@$end_epoch" +%Y-%m-%dT%H:%M:%SZ)" \
    --period $(( SILENCE_HOURS * 3600 )) --statistics Sum --output json)
events=$(jq '[.Datapoints[]?.Sum] | add // 0' <<< "$metric")
if [ "$(jq -n --argjson n "$events" '$n <= 0')" = "true" ]
then
    problems+=("no SSH login lines reached $LOG_GROUP in ${SILENCE_HOURS}h: the push has stopped or the host has been unreachable")
fi

if [ "${#problems[@]}" -eq 0 ]
then
    echo "Host access health: no port 22 rule, $events login events in ${SILENCE_HOURS}h"
    exit 0
fi

text="[Github action] Market data notification infra: host access health check failed:"
for problem in "${problems[@]}"
do
    echo "$problem" >&2
    text+=$'\n'"- $problem"
done
text+=$'\n'"Workflow: ${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

if [ -n "${STOCKS_TELEGRAM_DEV_BOT_TOKEN:-}" ] && [ -n "${STOCKS_TELEGRAM_DEV_ID:-}" ]
then
    # The bot token goes in curl's config on stdin, not in argv.
    curl --config - -fsS -o /dev/null \
        --data-urlencode "chat_id=$STOCKS_TELEGRAM_DEV_ID" \
        --data-urlencode "text=$text" <<EOF_CONFIG || echo "Telegram alert failed" >&2
url = "https://api.telegram.org/bot${STOCKS_TELEGRAM_DEV_BOT_TOKEN}/sendMessage"
EOF_CONFIG
else
    echo "Telegram dev chat not configured; alert printed only" >&2
fi
exit 1
