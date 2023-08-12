#! /bin/bash

#### Install docker
echo "Installing docker"

# Remove docker
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt remove $pkg; done
sudo apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
sudo rm -rf /var/lib/docker
sudo rm -rf /var/lib/containerd

sudo apt update
# Add docker repository
sudo apt -y install ca-certificates curl gnupg lsb-release

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo jammy)" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install docker
sudo apt update
sudo apt -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Create "docker" group, add users to allow sudo-less usage of docker
sudo groupadd docker || true
sudo usermod -a -G docker $USER
sudo usermod -a -G docker ubuntu
sudo systemctl start docker
echo "groups before $(groups)" 
newgrp docker
echo "groups after $(groups)"

sudo docker version
sudo docker compose version

# Start docker on boot
sudo systemctl enable docker.service
sudo systemctl enable containerd.service