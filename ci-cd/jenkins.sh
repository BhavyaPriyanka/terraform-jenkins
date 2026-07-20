#!/bin/bash
set -e

echo "========== Installing Jenkins =========="

# Add Jenkins repository
curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.repo \
    -o /etc/yum.repos.d/jenkins.repo

rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key

yum install -y \
    java-21-amazon-corretto \
    jenkins \
    rsync \
    xfsprogs

yum install -y \
    java-21-amazon-corretto \
    jenkins \
    git \
    rsync \
    xfsprogs \
    unzip \
    wget \
    jq \
    zip \
    tar \
    which \
    tree \
    vim
echo "========== Preparing Jenkins temp directory =========="

mkdir -p /var/lib/jenkins/tmp
chown -R jenkins:jenkins /var/lib/jenkins
chmod 1777 /var/lib/jenkins/tmp

mkdir -p /etc/systemd/system/jenkins.service.d

cat >/etc/systemd/system/jenkins.service.d/override.conf <<EOF
[Service]
Environment="JAVA_OPTS=-Djava.io.tmpdir=/var/lib/jenkins/tmp"
EOF

systemctl daemon-reload

echo "========== Waiting for EBS =========="

while true
do
    if [ -b /dev/nvme1n1 ]; then
        DEVICE=/dev/nvme1n1
        break
    elif [ -b /dev/xvdf ]; then
        DEVICE=/dev/xvdf
        break
    fi
    sleep 2
done

echo "EBS Device: $DEVICE"

echo "========== Formatting if required =========="

if ! blkid "$DEVICE" >/dev/null 2>&1
then
    mkfs.xfs "$DEVICE"
fi

mkdir -p /mnt/jenkins

mount "$DEVICE" /mnt/jenkins

UUID=$(blkid -s UUID -o value "$DEVICE")

echo "========== Copying Jenkins Home =========="

if [ -z "$(ls -A /mnt/jenkins)" ]; then
    rsync -a /var/lib/jenkins/ /mnt/jenkins/
fi

chown -R jenkins:jenkins /mnt/jenkins

umount /mnt/jenkins

mkdir -p /var/lib/jenkins

grep -q "/var/lib/jenkins" /etc/fstab || \
echo "UUID=$UUID /var/lib/jenkins xfs defaults,nofail 0 2" >> /etc/fstab

mount -a


echo "========== Starting Jenkins =========="

systemctl enable jenkins
systemctl start jenkins

echo "========== Waiting for Jenkins =========="

until curl -s http://localhost:8080/login >/dev/null
do
    sleep 5
done

echo "========== Installing Jenkins Plugins =========="

jenkins-plugin-cli --plugins \
workflow-aggregator \
git \
pipeline-stage-view \
pipeline-utility-steps \
credentials-binding \
nexus-artifact-uploader \
ssh-agent \
ansible

echo "========== Restarting Jenkins =========="

systemctl restart jenkins

echo "========== Completed =========="