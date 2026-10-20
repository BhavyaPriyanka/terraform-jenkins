#!/bin/bash

# Update
sudo yum update -y

# Java 21
sudo yum install -y java-21-amazon-corretto

# Maven
sudo yum install -y maven

# Git
sudo yum install -y git

# Node.js & npm
sudo yum install -y nodejs npm

# Docker
sudo yum install -y docker
sudo systemctl enable docker
sudo systemctl start docker

# AWS CLI
sudo yum install -y awscli

# Utilities
sudo yum install -y zip unzip wget curl jq tree vim

# Terraform
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install -y terraform

# Docker permissions
sudo usermod -aG docker ec2-user
sudo usermod -aG docker jenkins

echo "========== Preparing Jenkins Agent Workspace =========="

sudo mkdir -p /opt/jenkins
sudo chown -R ec2-user:ec2-user /opt/jenkins

mkdir -p /home/ec2-user/.ssh
chmod 700 /home/ec2-user/.ssh

sudo yum install zip -y


#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: Setup failed at line $LINENO" >&2' ERR

# Run as root so installation and system configuration are automatic.
if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash jenkins-agent-bootstrap.sh"
  exit 1
fi

source /etc/os-release
OS_ID="${ID,,}"
OS_VERSION="${VERSION_ID%%.*}"
ARCH="$(uname -m)"

echo "Configuring Jenkins agent: $OS_ID $VERSION_ID ($ARCH)"

# 1. Detect OS and install base dependencies
case "$OS_ID" in
  amzn)
    PM="dnf"
    [[ "$OS_VERSION" == "2" ]] && PM="yum"
    "$PM" update -y
    "$PM" install -y java-21-amazon-corretto git maven \
      nodejs npm unzip zip wget curl jq tree vim yum-utils
    "$PM" install -y docker
    ;;

  ubuntu|debian)
    PM="apt-get"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y openjdk-21-jdk maven git nodejs npm \
      docker.io unzip zip wget curl jq tree vim ca-certificates \
      gnupg lsb-release
    ;;

  rhel|rocky|almalinux|centos|fedora)
    PM="dnf"
    dnf install -y java-21-openjdk-devel maven git nodejs npm \
      unzip zip wget curl jq tree vim yum-utils \
      dnf-plugins-core ca-certificates
    # Install Docker CE from its official RPM repository.
    dnf config-manager --add-repo \
      https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
    ;;

  *)
    echo "Unsupported OS: $OS_ID. No changes beyond detection." >&2
    exit 1
    ;;
esac

# 2. Install AWS CLI v2 for the detected CPU architecture
case "$ARCH" in
  x86_64) AWS_ARCH="x86_64" ;;
  aarch64|arm64) AWS_ARCH="aarch64" ;;
  *)
    echo "Unsupported CPU architecture: $ARCH" >&2
    exit 1
    ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL \
  "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" \
  -o "$TMP_DIR/awscliv2.zip"

unzip -q "$TMP_DIR/awscliv2.zip" -d "$TMP_DIR"
if command -v aws >/dev/null 2>&1; then
  "$TMP_DIR/aws/install" --update
else
  "$TMP_DIR/aws/install"
fi

# 3. Install Terraform from HashiCorp's official repository
case "$OS_ID" in
  amzn|rhel|rocky|almalinux|centos|fedora)
    dnf config-manager --add-repo \
      https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
    dnf install -y terraform
    ;;
  ubuntu|debian)
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://apt.releases.hashicorp.com/gpg |
      gpg --dearmor --yes -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg
    chmod 0644 /etc/apt/keyrings/hashicorp-archive-keyring.gpg

    CODENAME="${VERSION_CODENAME:-}"
    if [[ -z "$CODENAME" ]]; then
      CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" \
      > /etc/apt/sources.list.d/hashicorp.list

    apt-get update
    apt-get install -y terraform
    ;;
esac

# 4. Configure Docker service
systemctl enable --now docker

# Add whichever users exist; do not assume a fixed agent username.
for USER_NAME in ec2-user jenkins ubuntu; do
  if id "$USER_NAME" >/dev/null 2>&1; then
    usermod -aG docker "$USER_NAME"
    echo "Added $USER_NAME to docker group"
  fi
done

# 5. Prepare workspace and SSH directory for common agent users
if id ec2-user >/dev/null 2>&1; then
  install -d -o ec2-user -g "$(id -gn ec2-user)" -m 0750 /opt/jenkins
  install -d -o ec2-user -g "$(id -gn ec2-user)" -m 0700 \
    /home/ec2-user/.ssh
fi

# 6. Verify installed tools and service
java -version
mvn -version
git --version
node --version
npm --version
aws --version
docker --version
terraform -version
systemctl is-active --quiet docker

echo "SUCCESS: Jenkins agent bootstrap completed."
echo "Reconnect the agent so new Docker group membership takes effect."
