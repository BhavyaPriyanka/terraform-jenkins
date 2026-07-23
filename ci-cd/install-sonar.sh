#!/bin/bash
set -euxo pipefail

# --------------------------------------------------
# Update OS
# --------------------------------------------------
yum update -y

# --------------------------------------------------
# Install Java 17
# --------------------------------------------------
yum install -y java-17-amazon-corretto wget unzip

# --------------------------------------------------
# Install PostgreSQL
# --------------------------------------------------
dnf install -y postgresql15-server postgresql15

postgresql-setup --initdb

systemctl enable postgresql
systemctl start postgresql

# --------------------------------------------------
# Create Sonar Database
# --------------------------------------------------
sudo -u postgres psql <<EOF
CREATE USER sonar WITH ENCRYPTED PASSWORD 'sonar';
CREATE DATABASE sonarqube OWNER sonar;
GRANT ALL PRIVILEGES ON DATABASE sonarqube TO sonar;
EOF

# --------------------------------------------------
# Create Sonar User
# --------------------------------------------------
id sonarqube >/dev/null 2>&1 || useradd sonarqube

# --------------------------------------------------
# Download SonarQube
# --------------------------------------------------
cd /opt

wget https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-25.6.0.109173.zip

unzip sonarqube-25.6.0.109173.zip

mv sonarqube-25.6.0.109173 sonarqube

chown -R sonarqube:sonarqube /opt/sonarqube

# --------------------------------------------------
# Configure SonarQube
# --------------------------------------------------
cat >> /opt/sonarqube/conf/sonar.properties <<EOF

sonar.jdbc.username=sonar
sonar.jdbc.password=sonar

sonar.jdbc.url=jdbc:postgresql://localhost:5432/sonarqube

sonar.web.host=0.0.0.0
sonar.web.port=9000

EOF

# --------------------------------------------------
# Linux Limits
# --------------------------------------------------
echo "vm.max_map_count=524288" >> /etc/sysctl.conf
echo "fs.file-max=131072" >> /etc/sysctl.conf

sysctl -p

cat >> /etc/security/limits.conf <<EOF
sonarqube   -   nofile   131072
sonarqube   -   nproc    8192
EOF

# --------------------------------------------------
# Create systemd Service
# --------------------------------------------------
cat > /etc/systemd/system/sonarqube.service <<EOF
[Unit]
Description=SonarQube
After=network.target postgresql.service

[Service]
Type=forking

User=sonarqube
Group=sonarqube

ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop

Restart=always
LimitNOFILE=131072
LimitNPROC=8192

[Install]
WantedBy=multi-user.target
EOF

# --------------------------------------------------
# Reload Systemd
# --------------------------------------------------
systemctl daemon-reload

systemctl enable sonarqube

systemctl start sonarqube

sleep 30

systemctl status sonarqube --no-pager

echo "======================================="
echo "SonarQube Installed Successfully"
echo "URL : http://<PUBLIC-IP>:9000"
echo "Default User : admin"
echo "Default Password : admin"
echo "======================================="