#! /bin/bash

#### Install redis
echo "Installing redis"
curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
sudo apt update
sudo apt -y install redis-server
sudo apt -y install redis-tools

sudo mkdir -p /etc/redis/conf.d
sudo tee -a /etc/redis/redis.conf <<< "include /etc/redis/conf.d/redis.conf" > /dev/null

# Run redis with systemd
# Set memory limit and policy
sudo tee -a /etc/redis/conf.d/redis.conf > /dev/null << EOF
supervised systemd

maxmemory 100mb
maxmemory-policy allkeys-lfu

# Snapshot after 60 seconds if at least 1 change is performed
save 60 1

appendonly yes
EOF

sudo systemctl enable redis-server
sudo systemctl start redis.service
echo "info memory" | redis-cli