#!/bin/bash
set -Eeuo pipefail

# SonarQube Community Build on Amazon Linux 2023.
# Run as root or as EC2 user-data. HTTP reverse proxy only; configure TLS separately.

SONAR_VERSION="26.3.0.120487"
SONAR_USER="sonar"
SONAR_HOME="/opt/sonarqube"
SONAR_DIR="/opt/sonarqube-${SONAR_VERSION}"
SONAR_ZIP="/tmp/sonarqube-${SONAR_VERSION}.zip"
DB_NAME="sonarqube"
DB_USER="sonarqube"
DB_ENV="/etc/sonarqube/database.env"
DOMAIN="sonar.localhelp.store"
LOG="/var/log/sonarqube-install.log"

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; echo "ERROR at line $LINENO (exit $rc); see $LOG"; exit "$rc"' ERR

echo "Installing SonarQube ${SONAR_VERSION}"

# 1. Packages and Java
dnf install -y java-21-amazon-corretto-devel unzip wget nginx shadow-utils procps-ng openssl postgresql16-server postgresql16
JAVA_BIN="$(readlink -f "$(command -v java)")"
JAVA_HOME="${JAVA_BIN%/bin/java}"
"$JAVA_BIN" -version

# 2. PostgreSQL
if [[ ! -s /var/lib/pgsql/data/PG_VERSION ]]; then postgresql-setup --initdb; fi
systemctl enable --now postgresql
for _ in $(seq 1 30); do
  runuser -u postgres -- psql -tAc 'SELECT 1' >/dev/null 2>&1 && break
  sleep 2
done
runuser -u postgres -- psql -tAc 'SELECT 1' >/dev/null

PG_HBA="$(runuser -u postgres -- psql -tAc 'SHOW hba_file' | xargs)"
cp -a "$PG_HBA" "${PG_HBA}.backup.$(date +%Y%m%d%H%M%S)"
sed -i '/^# BEGIN SONARQUBE LOCAL AUTH$/,/^# END SONARQUBE LOCAL AUTH$/d' "$PG_HBA"
tmp_hba="$(mktemp)"
{
  echo "# BEGIN SONARQUBE LOCAL AUTH"
  echo "host ${DB_NAME} ${DB_USER} 127.0.0.1/32 scram-sha-256"
  echo "host ${DB_NAME} ${DB_USER} ::1/128 scram-sha-256"
  echo "# END SONARQUBE LOCAL AUTH"
  cat "$PG_HBA"
} > "$tmp_hba"
cat "$tmp_hba" > "$PG_HBA"
rm -f "$tmp_hba"

install -d -o root -g root -m 700 /etc/sonarqube
DB_PASS=""
if [[ -f "$DB_ENV" ]]; then source "$DB_ENV"; fi
if [[ ! "${DB_PASS:-}" =~ ^[a-f0-9]{64}$ ]]; then DB_PASS="$(openssl rand -hex 32)"; fi

if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  printf "CREATE ROLE %s LOGIN PASSWORD '%s';\n" "$DB_USER" "$DB_PASS" | runuser -u postgres -- psql -v ON_ERROR_STOP=1
fi
printf "ALTER ROLE %s WITH LOGIN PASSWORD '%s';\n" "$DB_USER" "$DB_PASS" | runuser -u postgres -- psql -v ON_ERROR_STOP=1
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  runuser -u postgres -- createdb -O "$DB_USER" "$DB_NAME"
fi
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d "$DB_NAME" \
  -c "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};" \
  -c "GRANT ALL ON SCHEMA public TO ${DB_USER};"

printf 'DB_NAME=%s\nDB_USER=%s\nDB_PASS=%s\n' "$DB_NAME" "$DB_USER" "$DB_PASS" > "$DB_ENV"
chown root:root "$DB_ENV"; chmod 600 "$DB_ENV"
systemctl restart postgresql
PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null
unset PGPASSWORD
echo "PostgreSQL connection test passed"

# 3. Kernel settings and service account
cat > /etc/sysctl.d/99-sonarqube.conf <<'SYSCTL'
vm.max_map_count=524288
fs.file-max=131072
SYSCTL
sysctl --system
if ! id "$SONAR_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$SONAR_HOME" --shell /sbin/nologin "$SONAR_USER"
fi
install -d -o "$SONAR_USER" -g "$SONAR_USER" -m 755 /var/sonarqube/data /var/sonarqube/temp

# 4. Download and extract SonarQube
if [[ ! -x "$SONAR_DIR/bin/linux-x86-64/sonar.sh" ]]; then
  rm -f "$SONAR_ZIP"
  wget --show-progress "https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-${SONAR_VERSION}.zip" -O "$SONAR_ZIP"
  unzip -tq "$SONAR_ZIP"
  unzip -oq "$SONAR_ZIP" -d /opt
fi
test -x "$SONAR_DIR/bin/linux-x86-64/sonar.sh"
if [[ -e "$SONAR_HOME" && ! -L "$SONAR_HOME" ]]; then
  mv "$SONAR_HOME" "${SONAR_HOME}.backup.$(date +%Y%m%d%H%M%S)"
fi
ln -sfn "$SONAR_DIR" "$SONAR_HOME"

# 5. Configure SonarQube
SONAR_CONF="$SONAR_DIR/conf/sonar.properties"
touch "$SONAR_CONF"
sed -i -E \
  '/^[[:space:]]*sonar\.jdbc\.(username|password|url)[[:space:]]*=/d;
   /^[[:space:]]*sonar\.web\.(host|port|javaOpts)[[:space:]]*=/d;
   /^[[:space:]]*sonar\.(ce|search)\.javaOpts[[:space:]]*=/d;
   /^[[:space:]]*sonar\.path\.(data|temp)[[:space:]]*=/d' "$SONAR_CONF"
cat >> "$SONAR_CONF" <<PROPERTIES

# Localhelp settings
sonar.jdbc.username=${DB_USER}
sonar.jdbc.password=${DB_PASS}
sonar.jdbc.url=jdbc:postgresql://127.0.0.1:5432/${DB_NAME}
sonar.web.host=127.0.0.1
sonar.web.port=9000
sonar.path.data=/var/sonarqube/data
sonar.path.temp=/var/sonarqube/temp
sonar.web.javaOpts=-Xms512m -Xmx512m
sonar.ce.javaOpts=-Xms512m -Xmx512m
sonar.search.javaOpts=-Xms512m -Xmx512m
PROPERTIES

# Important: config must be readable by the service account.
chown -R "${SONAR_USER}:${SONAR_USER}" "$SONAR_DIR" /var/sonarqube
chown "${SONAR_USER}:${SONAR_USER}" "$SONAR_CONF"
chmod 640 "$SONAR_CONF"

# 6. systemd
cat > /etc/systemd/system/sonarqube.service <<SERVICE
[Unit]
Description=SonarQube Community Build
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=${SONAR_USER}
Group=${SONAR_USER}
WorkingDirectory=${SONAR_HOME}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="SONAR_JAVA_PATH=${JAVA_BIN}"
ExecStart=${SONAR_HOME}/bin/linux-x86-64/sonar.sh console
Restart=on-failure
RestartSec=10
LimitNOFILE=131072
LimitNPROC=8192
TimeoutStartSec=300
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
SERVICE

# 7. Nginx HTTP reverse proxy; TLS is separate.
cat > /etc/nginx/conf.d/sonarqube.conf <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    client_max_body_size 100M;
    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }
}
NGINX
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# 8. Start SonarQube and wait for health status
systemctl daemon-reload
systemctl enable sonarqube
systemctl restart sonarqube
for attempt in $(seq 1 60); do
  STATUS="$(curl -fsS --max-time 5 http://127.0.0.1:9000/api/system/status 2>/dev/null || true)"
  if printf '%s' "$STATUS" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"'; then
    echo "SUCCESS: SonarQube is UP: $STATUS"
    echo "URL: http://${DOMAIN}"
    echo "Install log: ${LOG}"
    exit 0
  fi
  echo "Waiting for SonarQube (${attempt}/60)..."
  sleep 10
done

echo "ERROR: SonarQube did not become healthy"
systemctl status sonarqube --no-pager -l || true
journalctl -u sonarqube -n 80 --no-pager || true
tail -n 80 "$SONAR_HOME/logs/sonar.log" 2>/dev/null || true
tail -n 80 "$SONAR_HOME/logs/web.log" 2>/dev/null || true
tail -n 80 "$SONAR_HOME/logs/es.log" 2>/dev/null || true
exit 1
