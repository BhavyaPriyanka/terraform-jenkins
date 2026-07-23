#!/bin/bash
set -euxo pipefail

# --------------------------------------------------
# Update OS
# --------------------------------------------------
yum update -y


# --------------------------------------------------
# Install Required Packages
# --------------------------------------------------
yum install -y \
java-17-amazon-corretto \
wget \
unzip \
postgresql15-server \
postgresql15


# --------------------------------------------------
# Configure PostgreSQL
# --------------------------------------------------
postgresql-setup --initdb || true

systemctl enable postgresql
systemctl start postgresql


# --------------------------------------------------
# Create Sonar Database
# --------------------------------------------------

sudo -u postgres psql <<EOF

DO \$\$
BEGIN

IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles 
    WHERE rolname = 'sonar'
)
THEN
    CREATE ROLE sonar LOGIN PASSWORD 'sonar';
END IF;

END
\$\$;


SELECT 'CREATE DATABASE sonarqube OWNER sonar'
WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'sonarqube'
)\gexec


EOF


# --------------------------------------------------
# Create SonarQube User
# --------------------------------------------------

id sonarqube >/dev/null 2>&1 || useradd sonarqube


# --------------------------------------------------
# Download SonarQube
# --------------------------------------------------

cd /opt


if [ ! -d "/opt/sonarqube" ]; then

wget -O sonarqube.zip \
https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-25.6.0.109173.zip


unzip sonarqube.zip


mv sonarqube-25.6.0.109173 sonarqube

fi


chown -R sonarqube:sonarqube /opt/sonarqube


# --------------------------------------------------
# Configure SonarQube Database
# --------------------------------------------------

cat >> /opt/sonarqube/conf/sonar.properties <<EOF

sonar.jdbc.username=sonar
sonar.jdbc.password=sonar

sonar.jdbc.url=jdbc:postgresql://localhost:5432/sonarqube

sonar.web.host=0.0.0.0
sonar.web.port=9000

EOF


# --------------------------------------------------
# Linux Kernel Settings
# --------------------------------------------------

cat >> /etc/sysctl.conf <<EOF

vm.max_map_count=524288
fs.file-max=131072

EOF


sysctl -p


# --------------------------------------------------
# User Limits
# --------------------------------------------------

cat >> /etc/security/limits.conf <<EOF

sonarqube   -   nofile   131072
sonarqube   -   nproc    8192

EOF


# --------------------------------------------------
# Create Systemd Service
# --------------------------------------------------

cat > /etc/systemd/system/sonarqube.service <<EOF

[Unit]
Description=SonarQube
After=network.target postgresql.service


[Service]

Type=forking

User=sonarqube
Group=sonarqube


Environment="SONAR_WEB_JAVAOPTS=-Xms512m -Xmx1024m"
Environment="SONAR_CE_JAVAOPTS=-Xms512m -Xmx1024m"
Environment="SONAR_SEARCH_JAVAOPTS=-Xms512m -Xmx1024m"


ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start

ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop


Restart=always
RestartSec=10


LimitNOFILE=131072
LimitNPROC=8192


[Install]

WantedBy=multi-user.target

EOF



# --------------------------------------------------
# Enable & Start SonarQube
# --------------------------------------------------

systemctl daemon-reload

systemctl enable sonarqube

systemctl restart sonarqube



# --------------------------------------------------
# Validation
# --------------------------------------------------

sleep 60


systemctl status sonarqube --no-pager || true


echo "======================================="
echo "SonarQube Installation Completed"
echo "URL : http://<PUBLIC-IP>:9000"
echo "Username : admin"
echo "Password : admin"
echo "======================================="