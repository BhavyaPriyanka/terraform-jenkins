#!/bin/bash
set -euxo pipefail

echo "========== Updating OS =========="
yum update -y

echo "========== Installing Docker =========="
yum install -y docker wget curl unzip jq

systemctl enable docker
systemctl start docker

echo "========== Pulling OWASP ZAP =========="
docker pull ghcr.io/zaproxy/zaproxy:stable

echo "========== Creating ZAP Data Directory =========="
mkdir -p /opt/zap
chmod 777 /opt/zap

echo "========== Creating systemd Service =========="

cat >/etc/systemd/system/zap.service <<EOF
[Unit]
Description=OWASP ZAP Docker
After=docker.service
Requires=docker.service

[Service]
Restart=always
RestartSec=10

ExecStart=/usr/bin/docker run --rm \
    --name zap \
    -p 8080:8080 \
    -v /opt/zap:/zap/wrk \
    ghcr.io/zaproxy/zaproxy:stable \
    zap.sh -daemon \
        -host 0.0.0.0 \
        -port 8080 \
        -config api.disablekey=true

ExecStop=/usr/bin/docker stop zap

[Install]
WantedBy=multi-user.target
EOF

echo "========== Starting ZAP =========="

systemctl daemon-reload
systemctl enable zap
systemctl restart zap

echo "========== Waiting for ZAP =========="
sleep 20

echo "========== Validation =========="

curl http://localhost:8080 || true

echo "======================================"
echo "OWASP ZAP Installed Successfully"
echo "URL : http://<PUBLIC-IP>:8080"
echo "API : http://<PUBLIC-IP>:8080"
echo "======================================"