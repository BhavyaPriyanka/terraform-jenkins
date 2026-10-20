#!/bin/bash
set -euo pipefail

echo "========== Installing Jenkins Controller =========="

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    exit 1
fi

# Required variables supplied by Terraform
: "$${agent_private_ip:?Terraform must provide agent_private_ip}"

# --------------------------------------------------
# 1. Install packages
# --------------------------------------------------
curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.repo \
    -o /etc/yum.repos.d/jenkins.repo

rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key

yum install -y \
    java-21-amazon-corretto \
    jenkins \
    git \
    rsync \
    xfsprogs \
    unzip wget jq zip tar which tree vim

# --------------------------------------------------
# 2. Install Trivy
# --------------------------------------------------
echo "========== Installing Trivy =========="

cat >/etc/yum.repos.d/trivy.repo <<'EOF'
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://aquasecurity.github.io/trivy-repo/rpm/public.key
EOF

yum install -y trivy
trivy --version

# --------------------------------------------------
# 3. Prepare Jenkins EBS volume
# --------------------------------------------------
echo "========== Waiting for Jenkins EBS =========="

DEVICE=""

for attempt in $(seq 1 120); do
    if [[ -b /dev/nvme1n1 ]]; then
        DEVICE="/dev/nvme1n1"
        break
    elif [[ -b /dev/xvdf ]]; then
        DEVICE="/dev/xvdf"
        break
    fi
    sleep 2
done

if [[ -z "$DEVICE" ]]; then
    echo "ERROR: Jenkins EBS volume not found."
    exit 1
fi

# Do not format a disk that already contains a filesystem.
if ! blkid "$DEVICE" >/dev/null 2>&1; then
    echo "Formatting new Jenkins EBS volume: $DEVICE"
    mkfs.xfs "$DEVICE"
fi

systemctl stop jenkins || true

UUID=$(blkid -s UUID -o value "$DEVICE")
if [[ -z "$UUID" ]]; then
    echo "ERROR: Could not determine EBS filesystem UUID."
    exit 1
fi

mkdir -p /mnt/jenkins /var/lib/jenkins

if ! grep -q "UUID=$UUID " /etc/fstab; then
    echo "UUID=$UUID /var/lib/jenkins xfs defaults,nofail 0 2" \
        >> /etc/fstab
fi

# Mount the data volume temporarily to initialize it.
if ! mountpoint -q /mnt/jenkins; then
    mount "$DEVICE" /mnt/jenkins
fi

if [[ -z "$(ls -A /mnt/jenkins)" ]]; then
    rsync -a /var/lib/jenkins/ /mnt/jenkins/
fi

umount /mnt/jenkins

# Ensure Jenkins Home is on EBS before configuring Jenkins.
mountpoint -q /var/lib/jenkins || mount /var/lib/jenkins

chown -R jenkins:jenkins /var/lib/jenkins

# --------------------------------------------------
# 4. Configure Jenkins temp directory and JCasC
# --------------------------------------------------
echo "========== Configuring Jenkins JCasC =========="

mkdir -p /var/lib/jenkins/tmp
chown jenkins:jenkins /var/lib/jenkins/tmp
chmod 1777 /var/lib/jenkins/tmp

mkdir -p /etc/systemd/system/jenkins.service.d

cat >/etc/systemd/system/jenkins.service.d/override.conf <<'EOF'
[Service]
Environment="JAVA_OPTS=-Djava.io.tmpdir=/var/lib/jenkins/tmp"
Environment="CASC_JENKINS_CONFIG=/var/lib/jenkins/jenkins.yaml"
EOF

# Initial JCasC configuration.
# Extend this file with credentials and other integrations as required.
cat >/var/lib/jenkins/jenkins.yaml <<'EOF'
jenkins:
  systemMessage: "Localhelp CI - managed by Configuration as Code"
  numExecutors: 0
  globalNodeProperties:
    - envVars:
        env:
          - key: AWS_DEFAULT_REGION
            value: us-east-1

unclassified:
  globalLibraries:
    libraries:
      - name: "localhelp-jenkins-shared-library"
        defaultVersion: "v1.9.13"
        implicit: false
        allowVersionOverride: true
        includeInChangesets: true
        retriever:
          modernSCM:
            scm:
              git:
                remote: "https://github.com/BhavyaPriyanka/localhelp-jenkins-shared-library.git"
EOF

chown jenkins:jenkins /var/lib/jenkins/jenkins.yaml
chmod 600 /var/lib/jenkins/jenkins.yaml

# --------------------------------------------------
# 5. Configure SSH access to Jenkins agent
# --------------------------------------------------
echo "========== Preparing SSH known_hosts =========="

install -d -o jenkins -g jenkins -m 700 /var/lib/jenkins/.ssh

ssh-keyscan -H "$agent_private_ip" \
    >> /var/lib/jenkins/.ssh/known_hosts

chown jenkins:jenkins /var/lib/jenkins/.ssh/known_hosts
chmod 600 /var/lib/jenkins/.ssh/known_hosts

# --------------------------------------------------
# 6. Install Jenkins plugins before startup
# --------------------------------------------------
echo "========== Installing Jenkins Plugins =========="

cat >/etc/jenkins/plugins.txt <<'EOF'
configuration-as-code
workflow-aggregator
git
github-branch-source
pipeline-stage-view
pipeline-utility-steps
pipeline-groovy-lib
credentials
credentials-binding
ssh-agent
sonar
nexus-artifact-uploader
ansible
EOF

# Download/install plugins and their dependencies.
jenkins-plugin-cli \
    --plugin-file /etc/jenkins/plugins.txt \
    --plugin-download-directory /var/lib/jenkins/plugins

chown -R jenkins:jenkins /var/lib/jenkins/plugins

# --------------------------------------------------
# 7. Start Jenkins
# --------------------------------------------------
echo "========== Starting Jenkins =========="

systemctl daemon-reload
systemctl enable jenkins
systemctl start jenkins

echo "========== Waiting for Jenkins =========="

for attempt in $(seq 1 60); do
    if curl -fsS http://localhost:8080/login >/dev/null; then
        echo "Jenkins is responding."
        break
    fi

    if [[ "$attempt" -eq 60 ]]; then
        echo "ERROR: Jenkins did not become ready."
        journalctl -u jenkins --no-pager -n 100
        exit 1
    fi

    sleep 5
done

echo "========== Jenkins Controller Setup Complete =========="
