#! /bin/bash

#### Install redis
echo "Installing redis"
curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
sudo apt-get update
sudo apt-get -y install redis-server=6:7.0.4-1rl1~focal1
sudo apt-get -y install redis-tools=6:7.0.4-1rl1~focal1

sudo mkdir -p /etc/redis/conf.d
sudo tee -a /etc/redis/redis.conf <<< "include /etc/redis/conf.d/redis.conf" > /dev/null

# Run redis with systemd
# Set memory limit and policy
sudo tee -a /etc/redis/conf.d/redis.conf > /dev/null << EOF
supervised systemd

maxmemory 50mb
maxmemory-policy allkeys-lfu
EOF

sudo systemctl enable redis-server
sudo systemctl start redis.service
echo "info memory" | redis-cli