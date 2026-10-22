
#!/bin/bash
set -Eeuo pipefail

exec > >(tee -a /var/log/jenkins-bootstrap.log | logger -t jenkins-bootstrap -s 2>/dev/console) 2>&1

trap 'rc=$?; echo "ERROR: Bootstrap failed at line $${LINENO}: $${BASH_COMMAND} (exit=$${rc})" >&2; ...'
echo "========== Jenkins Controller Setup =========="

# Configure for your EC2 environment.
JENKINS_DATA_DEVICE="/dev/nvme1n1"
JENKINS_HOME="/var/lib/jenkins"
PLUGIN_MANAGER_VERSION="2.15.0"
PLUGIN_MANAGER_JAR="/opt/jenkins/jenkins-plugin-manager.jar"
PLUGIN_STAGING="/var/cache/jenkins-plugin-manager/plugins"

# 1. Install required packages.
# Use curl-minimal instead of curl to avoid the AL2023 conflict.
dnf install -y \
  fontconfig \
  java-21-amazon-corretto \
  git rsync xfsprogs unzip wget jq zip tar \
  which tree vim curl-minimal openssh-clients

java -version

# 2. Configure the official Jenkins stable repository.
rpm --import https://pkg.jenkins.io/rpm-stable/jenkins.io-2023.key

cat > /etc/yum.repos.d/jenkins.repo <<'REPO'
[jenkins]
name=Jenkins Stable
baseurl=https://pkg.jenkins.io/rpm-stable
gpgcheck=1
gpgkey=https://pkg.jenkins.io/rpm-stable/jenkins.io-2023.key
REPO

dnf install -y jenkins

# 3. Prepare Jenkins configuration directory.
install -d -m 0755 /etc/jenkins
install -d -m 0755 /opt/jenkins

# 4. Prepare the dedicated Jenkins EBS volume safely.
# IMPORTANT: verify the device mapping for your instance.
if [[ ! -b "$JENKINS_DATA_DEVICE" ]]; then
  echo "ERROR: Jenkins EBS device not found: $JENKINS_DATA_DEVICE"
  lsblk
  exit 1
fi

install -d "$JENKINS_HOME"

if mountpoint -q "$JENKINS_HOME"; then
  echo "Jenkins home is already mounted."
else
  NEW_FILESYSTEM=0

  if blkid "$JENKINS_DATA_DEVICE" >/dev/null 2>&1; then
    FSTYPE="$(blkid -o value -s TYPE "$JENKINS_DATA_DEVICE" || true)"

    if [[ "$FSTYPE" != "xfs" ]]; then
      echo "ERROR: Existing filesystem is '$FSTYPE', not XFS."
      echo "Refusing to format or overwrite the volume."
      exit 1
    fi
  else
    # Only format a volume with no detected filesystem.
    # Confirm it is the intended blank EBS volume before launch.
    echo "Formatting blank Jenkins EBS volume: $JENKINS_DATA_DEVICE"
    mkfs.xfs "$JENKINS_DATA_DEVICE"
    NEW_FILESYSTEM=1
  fi

  if [[ "$NEW_FILESYSTEM" -eq 1 ]]; then
    TEMP_MOUNT="/mnt/jenkins-ebs-init"
    install -d "$TEMP_MOUNT"
    mount "$JENKINS_DATA_DEVICE" "$TEMP_MOUNT"

    # Preserve any existing Jenkins files on the root disk.
    rsync -aHAX "$JENKINS_HOME/" "$TEMP_MOUNT/"

    umount "$TEMP_MOUNT"
    rmdir "$TEMP_MOUNT"
  fi

  VOLUME_UUID="$(blkid -s UUID -o value "$JENKINS_DATA_DEVICE")"

  if ! grep -qE "UUID=$${VOLUME_UUID}[[:space:]]" /etc/fstab; then
    echo "UUID=$${VOLUME_UUID} $${JENKINS_HOME} xfs defaults,nofail 0 2" >> /etc/fstab
  fi

  mount "$JENKINS_HOME"
fi

# 5. Configure plugin list.
cat > /etc/jenkins/plugins.txt <<'PLUGINS'
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
PLUGINS

# 6. Download the official standalone Plugin Installation Manager.
curl -fL --retry 3 \
  -o "$${PLUGIN_MANAGER_JAR}" \
  "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/$${PLUGIN_MANAGER_VERSION}/jenkins-plugin-manager-$${PLUGIN_MANAGER_VERSION}.jar"

java -jar "$PLUGIN_MANAGER_JAR" --version

# Stage plugins separately so the manager does not erase
# an existing Jenkins plugins directory.
install -d "$PLUGIN_STAGING"
install -d -o jenkins -g jenkins "$JENKINS_HOME/plugins"

java -jar "$PLUGIN_MANAGER_JAR" \
  --war /usr/share/java/jenkins.war \
  --plugin-file /etc/jenkins/plugins.txt \
  --plugin-download-directory "$PLUGIN_STAGING"

# Copy downloaded plugins and dependencies into Jenkins home.
rsync -a "$PLUGIN_STAGING/" "$JENKINS_HOME/plugins/"
chown -R jenkins:jenkins "$JENKINS_HOME/plugins"

# 7. CUSTOM CONFIGURATION
# Retain your existing JCasC YAML generation and SSH-agent
# configuration here. In your previous setup, JCasC was stored at:
# /var/lib/jenkins/jenkins.yaml
#
# If that file exists, configure Jenkins to load it:
if [[ -f "$JENKINS_HOME/jenkins.yaml" ]]; then
  install -d /etc/systemd/system/jenkins.service.d

  cat > /etc/systemd/system/jenkins.service.d/override.conf <<'OVERRIDE'
[Service]
Environment="CASC_JENKINS_CONFIG=/var/lib/jenkins/jenkins.yaml"
OVERRIDE
fi

# 8. Set ownership and start Jenkins.
chown jenkins:jenkins "$JENKINS_HOME"
systemctl daemon-reload
systemctl enable jenkins
systemctl start jenkins

# 9. Wait for Jenkins to respond.
for attempt in $(seq 1 60); do
  if systemctl is-active --quiet jenkins &&
     curl -fsS http://localhost:8080/login -o /dev/null; then
    echo "========== Jenkins is READY =========="
    systemctl status jenkins --no-pager
    exit 0
  fi

  sleep 5
done

echo "ERROR: Jenkins did not become ready within 5 minutes."
systemctl status jenkins --no-pager || true
journalctl -u jenkins -n 100 --no-pager || true
exit 1
