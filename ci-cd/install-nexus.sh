#!/bin/bash

set -e

# Update packages
dnf update -y

# Install Java 17
dnf install java-17-amazon-corretto -y

# Create nexus user
useradd nexus

# Download Nexus
cd /opt

wget https://download.sonatype.com/nexus/3/nexus-3.94.0-12-linux-x86_64.tar.gz

# Extract
tar -xzf nexus-3.94.0-12-linux-x86_64.tar.gz

# Create data directory
mkdir -p /opt/sonatype-work

# Permissions
chown -R nexus:nexus /opt/nexus-3.94.0-12
chown -R nexus:nexus /opt/sonatype-work

# Configure Nexus user
echo 'run_as_user="nexus"' > /opt/nexus-3.94.0-12/bin/nexus.rc

# Reduce JVM memory for free-tier instances
cat > /opt/nexus-3.94.0-12/bin/nexus.vmoptions <<EOF
-Xms512m
-Xmx512m
-XX:MaxDirectMemorySize=512m
-XX:+UnlockDiagnosticVMOptions
-XX:+LogVMOutput
-XX:LogFile=/opt/sonatype-work/nexus3/log/jvm.log
-XX:-OmitStackTraceInFastThrow
-Djava.net.preferIPv4Stack=true
EOF

# Create systemd service
cat > /etc/systemd/system/nexus.service <<EOF
[Unit]
Description=Nexus Repository Manager
After=network.target

[Service]
Type=forking
LimitNOFILE=65536
User=nexus
Group=nexus

ExecStart=/opt/nexus-3.94.0-12/bin/nexus start
ExecStop=/opt/nexus-3.94.0-12/bin/nexus stop

Restart=on-abort

[Install]
WantedBy=multi-user.target
EOF

# Enable and start Nexus
systemctl daemon-reload
systemctl enable nexus
systemctl start nexus

echo "Nexus installation completed"