#! /bin/bash

# GitHub API call with the deploy token in curl's config on stdin, never in argv, where
# the runner's process list would show it. A heredoc, not printf: `set -x` traces a
# builtin's arguments but never a heredoc's body.
# usage: github_api <curl arguments...>   (reads MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN)
github_api () {
    curl --config - -fsSL -H "Accept: application/vnd.github+json" "$@" <<EOF_CONFIG
header = "Authorization: token ${MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN:?MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN is not set}"
EOF_CONFIG
}
