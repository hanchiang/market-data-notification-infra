#!/bin/bash
cat << CONFIG > ~/.ssh/config
Host production
  HostName i-0123456789abcdef0
  UserKnownHostsFile ~/.ssh/known_hosts
  ProxyCommand aws ssm start-session --target %h --document-name MarketDataNotification-SSH22
CONFIG
