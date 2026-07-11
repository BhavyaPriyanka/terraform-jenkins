#!/bin/bash
set -e

# Add Jenkins repository
curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.repo \
    -o /etc/yum.repos.d/jenkins.repo

# Import Jenkins GPG key
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key

# Install Java 21 (LTS) and Jenkins
dnf install -y java-21-openjdk fontconfig jenkins

# Enable and start Jenkins
systemctl enable --now jenkins