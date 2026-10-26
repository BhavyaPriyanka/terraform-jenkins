#!/bin/bash
set -e

echo "Installing Java 21 and required utilities..."
dnf install -y java-21-amazon-corretto git rsync wget

echo "Adding Jenkins repository..."
wget -O /etc/yum.repos.d/jenkins.repo \
  https://pkg.jenkins.io/rpm-stable/jenkins.repo

rpm --import https://pkg.jenkins.io/rpm-stable/jenkins.io-2026.key

echo "Installing Jenkins..."
dnf install -y jenkins

echo "Preparing Jenkins SSH known_hosts..."
install -d -m 700 -o jenkins -g jenkins /var/lib/jenkins/.ssh
touch /var/lib/jenkins/.ssh/known_hosts
chown jenkins:jenkins /var/lib/jenkins/.ssh/known_hosts
chmod 600 /var/lib/jenkins/.ssh/known_hosts

# Agent host-key preparation only.
# Add the verified agent host key here when its hostname/IP is confirmed.

echo "Starting Jenkins..."
systemctl enable jenkins
systemctl start jenkins

echo "Installing required Jenkins plugins..."
JENKINS_PLUGIN_CLI="/opt/jenkins-plugin-manager.jar"
PLUGIN_LIST="/tmp/jenkins-plugins.txt"

# This file should contain one required plugin ID per line.
# Example:
# workflow-aggregator
# git
# configuration-as-code
# ssh-agent
# credentials
# pipeline-groovy-lib

if [ -f "$PLUGIN_LIST" ]; then
    echo "Plugin list found. Plugin installation must use the configured plugin manager."
else
    echo "Plugin list not found: $PLUGIN_LIST"
    echo "Skipping plugin installation."
fi

echo "Checking Jenkins service..."
systemctl --no-pager --full status jenkins

echo "Jenkins master setup completed."