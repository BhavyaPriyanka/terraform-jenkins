#!/bin/bash
set -e

# Add Jenkins repository
curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.repo \
    -o /etc/yum.repos.d/jenkins.repo

# Import Jenkins GPG key
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key

# Install Java
sudo yum install -y java-21-amazon-corretto

# Install Jenkins
sudo yum install -y jenkins



echo "Creating Jenkins temporary directory..."

sudo mkdir -p /var/lib/jenkins/tmp

echo "Setting ownership and permissions..."

sudo chown jenkins:jenkins /var/lib/jenkins/tmp
sudo chmod 1777 /var/lib/jenkins/tmp


echo "Creating Jenkins systemd override..."

sudo mkdir -p /etc/systemd/system/jenkins.service.d

sudo tee /etc/systemd/system/jenkins.service.d/override.conf >/dev/null <<EOF
[Service]
Environment="JAVA_OPTS=-Djava.io.tmpdir=/var/lib/jenkins/tmp"
EOF


echo "Reloading systemd configuration..."

sudo systemctl daemon-reload


echo "Restarting Jenkins..."

sudo systemctl restart jenkins


echo "Checking Jenkins environment..."

sudo systemctl show jenkins --property=Environment


echo "Jenkins temp directory configuration completed successfully."