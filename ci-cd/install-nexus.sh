#!/bin/bash
set -e

# Update system
yum update -y

# Install required packages
yum install -y java-17-amazon-corretto wget tar

# Create nexus user if it doesn't exist
id nexus >/dev/null 2>&1 || useradd nexus

# Download Nexus
cd /opt
wget -O nexus.tar.gz https://download.sonatype.com/nexus/3/nexus-3.94.0-12-linux-x86_64.tar.gz

# Extract Nexus
tar -xzf nexus.tar.gz

# Rename for convenience
mv nexus-3.94.0-12 nexus

# Create data directory
mkdir -p /opt/sonatype-work

# Set ownership
chown -R nexus:nexus /opt/nexus
chown -R nexus:nexus /opt/sonatype-work

# Run Nexus as nexus user
echo 'run_as_user="nexus"' > /opt/nexus/bin/nexus.rc

# Reduce JVM memory (DON'T overwrite nexus.vmoptions)
sed -i 's/^-Xms.*/-Xms512m/' /opt/nexus/bin/nexus.vmoptions
sed -i 's/^-Xmx.*/-Xmx512m/' /opt/nexus/bin/nexus.vmoptions
sed -i 's/^-XX:MaxDirectMemorySize=.*/-XX:MaxDirectMemorySize=512m/' /opt/nexus/bin/nexus.vmoptions

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
ExecStart=/opt/nexus/bin/nexus start
ExecStop=/opt/nexus/bin/nexus stop
Restart=on-failure
TimeoutStartSec=600
TimeoutStopSec=600

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd
systemctl daemon-reload

# Enable Nexus
systemctl enable nexus

# Start Nexus
systemctl start nexus

# Wait for startup
sleep 30

# Show status
systemctl status nexus --no-pager

echo "======================================"
echo "Nexus Installed Successfully!"
echo "URL: http://<PUBLIC-IP>:8081"
echo "======================================"

#repo URL
# http://nexus-server:8081/repository/maven-release/ 