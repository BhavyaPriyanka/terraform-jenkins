
#!/bin/bash
set -Eeuo pipefail

trap 'rc=$?; trap - ERR; echo "ERROR: Bootstrap failed at line $LINENO: $BASH_COMMAND (exit=$rc)" >&2; systemctl daemon-reload || true; systemctl enable jenkins || true; systemctl start jenkins || true; systemctl status jenkins --no-pager || true; journalctl -u jenkins -n 50 --no-pager || true; exit "$rc"' ERR

echo "========== Jenkins Controller Setup =========="

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    exit 1
fi

# Terraform substitutes the Jenkins agent private IP.
AGENT_IP="${agent_private_ip}"

# --------------------------------------------------
# 1. Install packages
# --------------------------------------------------
echo "========== Installing Jenkins and Utilities =========="

mkdir -p /etc/yum.repos.d /etc/jenkins

curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.repo \
    -o /etc/yum.repos.d/jenkins.repo

rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key

yum install -y \
    java-21-amazon-corretto \
    jenkins \
    git \
    rsync \
    xfsprogs \
    unzip wget jq zip tar which tree vim curl

rpm -q jenkins
command -v java

# --------------------------------------------------
# 2. Prepare Jenkins EBS volume
# --------------------------------------------------
echo "========== Preparing Jenkins EBS =========="

DEVICE=""

for attempt in $(seq 1 60); do
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

# Format only a blank disk. Never overwrite existing signatures.
if ! blkid "$DEVICE" >/dev/null 2>&1; then
    if wipefs -n "$DEVICE" | grep -q .; then
        echo "ERROR: Disk signatures found on $DEVICE; refusing to format."
        exit 1
    fi

    if lsblk -nrpo MOUNTPOINT "$DEVICE" | grep -q '[^[:space:]]'; then
        echo "ERROR: $DEVICE is mounted; refusing to format."
        exit 1
    fi

    echo "Formatting blank Jenkins EBS volume: $DEVICE"
    mkfs.xfs "$DEVICE"
fi

UUID=$(blkid -s UUID -o value "$DEVICE")

if [[ -z "$UUID" ]]; then
    echo "ERROR: Cannot determine EBS filesystem UUID."
    exit 1
fi

mkdir -p /mnt/jenkins /var/lib/jenkins

# Add the persistent mount entry once.
if ! grep -Fq "UUID=$UUID " /etc/fstab; then
    echo "UUID=$UUID /var/lib/jenkins xfs defaults,nofail 0 2" \
        >> /etc/fstab
fi

# If Jenkins home is not mounted, migrate existing data safely.
if ! mountpoint -q /var/lib/jenkins; then
    mount "$DEVICE" /mnt/jenkins

    if [[ -z "$(ls -A /mnt/jenkins)" ]]; then
        rsync -a /var/lib/jenkins/ /mnt/jenkins/
    fi

    umount /mnt/jenkins
    mount /var/lib/jenkins
fi

chown -R jenkins:jenkins /var/lib/jenkins

# --------------------------------------------------
# 3. Configure Jenkins
# --------------------------------------------------
echo "========== Configuring Jenkins =========="

mkdir -p /var/lib/jenkins/tmp
mkdir -p /etc/systemd/system/jenkins.service.d

chown jenkins:jenkins /var/lib/jenkins/tmp
chmod 1777 /var/lib/jenkins/tmp

cat >/etc/systemd/system/jenkins.service.d/override.conf <<'EOF'
[Service]
Environment="JAVA_OPTS=-Djava.io.tmpdir=/var/lib/jenkins/tmp"
Environment="CASC_JENKINS_CONFIG=/var/lib/jenkins/jenkins.yaml"
EOF

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
# 4. Configure SSH access to Jenkins agent
# --------------------------------------------------
echo "========== Configuring Agent SSH =========="

install -d -o jenkins -g jenkins -m 700 /var/lib/jenkins/.ssh

touch /var/lib/jenkins/.ssh/known_hosts
chown jenkins:jenkins /var/lib/jenkins/.ssh/known_hosts
chmod 600 /var/lib/jenkins/.ssh/known_hosts

if ! ssh-keygen -F "$AGENT_IP" \
    -f /var/lib/jenkins/.ssh/known_hosts >/dev/null 2>&1; then
    if ! ssh-keyscan -T 5 -H "$AGENT_IP" \
    >> /var/lib/jenkins/.ssh/known_hosts; then
    echo "WARNING: Could not scan agent SSH key at $AGENT_IP."
    echo "Check agent reachability and SSH security-group rules."
fi
fi

chown jenkins:jenkins /var/lib/jenkins/.ssh/known_hosts

# --------------------------------------------------
# 5. Install Jenkins plugins
# --------------------------------------------------
echo "========== Installing Jenkins Plugins =========="

mkdir -p /etc/jenkins /var/lib/jenkins/plugins

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

if ! command -v jenkins-plugin-cli >/dev/null 2>&1; then
    echo "ERROR: jenkins-plugin-cli is missing."
    echo "Verify the Jenkins package installation before continuing."
    exit 1
fi

jenkins-plugin-cli \
    --plugin-file /etc/jenkins/plugins.txt \
    --plugin-download-directory /var/lib/jenkins/plugins

chown -R jenkins:jenkins /var/lib/jenkins/plugins

# --------------------------------------------------
# 6. Start and verify Jenkins
# --------------------------------------------------
echo "========== Starting Jenkins =========="

systemctl daemon-reload
systemctl enable jenkins

if ! systemctl start jenkins; then
    echo "ERROR: Jenkins failed to start."
    systemctl status jenkins --no-pager || true
    journalctl -u jenkins -n 100 --no-pager || true
    exit 1
fi

echo "========== Verifying Jenkins =========="

for attempt in $(seq 1 60); do
    if systemctl is-active --quiet jenkins &&
       curl -fsS --max-time 5 \
           http://localhost:8080/login >/dev/null; then
        echo "SUCCESS: Jenkins is active and responding on port 8080."
        systemctl status jenkins --no-pager
        exit 0
    fi

    sleep 5
done

echo "ERROR: Jenkins did not become healthy within 5 minutes."
systemctl status jenkins --no-pager || true
journalctl -u jenkins -n 100 --no-pager || true
exit 1