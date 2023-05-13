#!/bin/bash

sudo apt-get -y install zip

# Setup sudo to allow no-password sudo for "admin" group and adding "han" user
sudo groupadd -r admin
sudo useradd -m -s /bin/bash $USER
sudo usermod -a -G admin $USER
sudo cp /etc/sudoers /etc/sudoers.orig
echo "$USER  ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USER

# Installing SSH key
echo "Adding public ssh keys in authorized_keys/"
sudo mkdir -p /home/$USER/.ssh
sudo chmod 700 /home/$USER/.ssh
sudo cp $SSH_PUBLIC_KEY_PATH /home/$USER/.ssh/authorized_keys
sudo chmod 600 /home/$USER/.ssh/authorized_keys
sudo chown -R $USER /home/$USER/.ssh
sudo usermod --shell /bin/bash $USER

# open ssh port
sudo ufw allow OpenSSH

# Set vim as default editor, configurations
sudo update-alternatives --set editor /usr/bin/vim.basic

sudo touch /home/$USER/.vimrc
cat <<EOF | sudo tee -a /home/$USER/.vimrc > /dev/null
set number
set expandtab
set tabstop=2
set shiftwidth=2
EOF
sudo chown $USER:$USER /home/$USER/.vimrc

cat <<EOF | sudo tee -a /root/.vimrc > /dev/null
set number
set expandtab
set tabstop=2
set shiftwidth=2
EOF