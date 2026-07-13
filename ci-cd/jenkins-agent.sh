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

sudo yum install zip -y