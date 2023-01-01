#! /bin/bash

#### Install docker
echo "Installing docker"

# Remove docker
sudo apt-get -y remove docker-desktop || true
rm -r $HOME/.docker/desktop || true
sudo rm /usr/local/bin/com.docker.cli || true
sudo apt-get -y purge docker-desktop || true

# Add docker repository
sudo apt-get -y install ca-certificates curl gnupg lsb-release
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install docker
sudo apt-get update
sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin

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