#!/bin/bash
# A strict, pinned SSH entry and strict one-off options.
cat << CONFIG > ~/.ssh/config
Host production
  HostName i-0123456789abcdef0
  HostKeyAlias market-data-notification-production
  StrictHostKeyChecking yes
  UserKnownHostsFile ~/.ssh/known_hosts
  ProxyCommand aws ssm start-session --target %h --document-name MarketDataNotification-SSH22
CONFIG
ssh -o StrictHostKeyChecking=yes -o BatchMode=yes production true
ssh-keygen -F market-data-notification-production -f ~/.ssh/known_hosts
curl -H 'Host: example.com' http://127.0.0.1/
