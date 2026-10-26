
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Localhelp SonarQube Community Build
# Amazon Linux 2023 | Java 21 | PostgreSQL 16 | Nginx
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script using sudo."
    exit 1
fi

umask 077
exec > >(tee -a /var/log/sonarqube-install.log) 2>&1
trap 'rc=$?; echo "ERROR: Script failed at line ${LINENO}, exit code ${rc}."; exit "$rc"' ERR

DOMAIN="sonar.localhelp.store"
SONAR_VERSION="26.3.0.120487"
SONAR_USER="sonar"
SONAR_HOME="/opt/sonarqube"
SONAR_DIR="/opt/sonarqube-${SONAR_VERSION}"
SONAR_ZIP="/tmp/sonarqube-${SONAR_VERSION}.zip"
SONAR_CONF="${SONAR_HOME}/conf/sonar.properties"

DB_NAME="sonarqube"
DB_USER="sonarqube"
DB_ENV="/etc/sonarqube/database.env"
ROTATE_DB_PASSWORD="${ROTATE_DB_PASSWORD:-false}"

echo "============================================================"
echo "Starting SonarQube installation/configuration"
echo "Domain: ${DOMAIN}"
echo "Version: ${SONAR_VERSION}"
echo "Log: /var/log/sonarqube-install.log"
echo "============================================================"

# 1. Install packages.
# Do not install the full curl package: AL2023 may use curl-minimal.
echo "[1/10] Installing required packages..."

dnf install -y \
    java-21-amazon-corretto-devel \
    unzip \
    wget \
    nginx \
    shadow-utils \
    procps-ng \
    openssl \
    postgresql16-server \
    postgresql16

command -v curl >/dev/null || {
    echo "ERROR: curl command is unavailable."
    exit 1
}

JAVA_BIN="$(readlink -f "$(command -v java)")"
JAVA_HOME="${JAVA_BIN%/bin/java}"

echo "Java: ${JAVA_BIN}"
"${JAVA_BIN}" -version

# 2. Initialize and start PostgreSQL.
echo "[2/10] Configuring PostgreSQL..."

if [[ ! -s /var/lib/pgsql/data/PG_VERSION ]]; then
    postgresql-setup --initdb
fi

systemctl enable --now postgresql

for attempt in $(seq 1 30); do
    if runuser -u postgres -- psql -tAc 'SELECT 1' >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

runuser -u postgres -- psql -tAc 'SELECT 1' >/dev/null

# 3. Configure password authentication for localhost.
echo "[3/10] Configuring PostgreSQL authentication..."

PG_HBA="$(runuser -u postgres -- psql -tAc 'SHOW hba_file;')"
PG_HBA="$(echo "${PG_HBA}" | xargs)"

if [[ ! -f "${PG_HBA}" ]]; then
    echo "ERROR: PostgreSQL authentication file not found: ${PG_HBA}"
    exit 1
fi

cp -a "${PG_HBA}" "${PG_HBA}.backup.$(date +%Y%m%d%H%M%S)"

# Remove this script's previous managed block to make reruns safe.
sed -i \
    '/^# BEGIN LOCALHELP SONARQUBE AUTH$/,/^# END LOCALHELP SONARQUBE AUTH$/d' \
    "${PG_HBA}"

PG_HBA_TMP="$(mktemp)"
{
    echo "# BEGIN LOCALHELP SONARQUBE AUTH"
    echo "host all all 127.0.0.1/32 scram-sha-256"
    echo "host all all ::1/128 scram-sha-256"
    echo "# END LOCALHELP SONARQUBE AUTH"
    cat "${PG_HBA}"
} > "${PG_HBA_TMP}"

cat "${PG_HBA_TMP}" > "${PG_HBA}"
rm -f "${PG_HBA_TMP}"

# 4. Create/reuse a strong database password.
echo "[4/10] Configuring the SonarQube database..."

install -d -o root -g root -m 700 /etc/sonarqube

DB_PASS=""

if [[ -f "${DB_ENV}" && "${ROTATE_DB_PASSWORD}" != "true" ]]; then
    # This file is root-owned and mode 600.
    source "${DB_ENV}"
fi

if [[ "${ROTATE_DB_PASSWORD}" == "true" ||
      ! "${DB_PASS:-}" =~ ^[a-f0-9]{64}$ ]]; then
    DB_PASS="$(openssl rand -hex 32)"
fi

# The password is hexadecimal, so it is safe in this SQL statement.
printf "ALTER ROLE %s WITH LOGIN PASSWORD '%s';\n" \
    "${DB_USER}" "${DB_PASS}" |
    runuser -u postgres -- psql -v ON_ERROR_STOP=1

# If the role did not exist, create it.
# The ALTER above fails for a missing role, so check/create beforehand
# using a separate role-existence check on subsequent runs.
#
# The role is created below when absent; the ALTER is repeated afterward.
if ! runuser -u postgres -- psql -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
    printf "CREATE ROLE %s LOGIN PASSWORD '%s';\n" \
        "${DB_USER}" "${DB_PASS}" |
        runuser -u postgres -- psql -v ON_ERROR_STOP=1
fi

# Ensure the password is set, including on first creation.
printf "ALTER ROLE %s WITH LOGIN PASSWORD '%s';\n" \
    "${DB_USER}" "${DB_PASS}" |
    runuser -u postgres -- psql -v ON_ERROR_STOP=1

if ! runuser -u postgres -- psql -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    runuser -u postgres -- createdb -O "${DB_USER}" "${DB_NAME}"
fi

runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
    -c "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};" \
    -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};" \
    -d "${DB_NAME}" \
    -c "GRANT ALL ON SCHEMA public TO ${DB_USER};"

# Save the password securely for future reruns.
printf 'DB_NAME=%s\nDB_USER=%s\nDB_PASS=%s\n' \
    "${DB_NAME}" "${DB_USER}" "${DB_PASS}" > "${DB_ENV}"
chown root:root "${DB_ENV}"
chmod 600 "${DB_ENV}"

systemctl restart postgresql

# Verify password authentication before continuing.
PGPASSWORD="${DB_PASS}" psql \
    -h 127.0.0.1 \
    -U "${DB_USER}" \
    -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 \
    -c 'SELECT 1;' >/dev/null

unset PGPASSWORD

echo "PostgreSQL authentication test passed."

# 5. Configure kernel settings and the service account.
echo "[5/10] Configuring system requirements..."

cat > /etc/sysctl.d/99-sonarqube.conf <<'SYSCTL'
vm.max_map_count=524288
fs.file-max=131072
SYSCTL

sysctl --system

if ! id "${SONAR_USER}" >/dev/null 2>&1; then
    useradd --system \
        --home-dir "${SONAR_HOME}" \
        --shell /sbin/nologin \
        "${SONAR_USER}"
fi

install -d -o "${SONAR_USER}" -g "${SONAR_USER}" -m 755 \
    /var/sonarqube \
    /var/sonarqube/data \
    /var/sonarqube/temp

# 6. Download and extract SonarQube.
echo "[6/10] Downloading/checking SonarQube..."

if [[ ! -x "${SONAR_DIR}/bin/linux-x86-64/sonar.sh" ]]; then
    rm -rf "${SONAR_DIR}"

    if [[ ! -f "${SONAR_ZIP}" ]] ||
       ! unzip -tq "${SONAR_ZIP}" >/dev/null 2>&1; then
        rm -f "${SONAR_ZIP}"
        wget --show-progress \
            "https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-${SONAR_VERSION}.zip" \
            -O "${SONAR_ZIP}"
    fi

    unzip -tq "${SONAR_ZIP}"
    unzip -oq "${SONAR_ZIP}" -d /opt
fi

if [[ ! -x "${SONAR_DIR}/bin/linux-x86-64/sonar.sh" ]]; then
    echo "ERROR: SonarQube extraction failed."
    exit 1
fi

# Preserve an existing real directory rather than deleting it.
if [[ -e "${SONAR_HOME}" && ! -L "${SONAR_HOME}" ]]; then
    mv "${SONAR_HOME}" "${SONAR_HOME}.backup.$(date +%Y%m%d%H%M%S)"
fi

ln -sfn "${SONAR_DIR}" "${SONAR_HOME}"

# 7. Configure SonarQube properties without duplicate entries.
echo "[7/10] Configuring SonarQube..."

touch "${SONAR_CONF}"

# Remove managed settings wherever they occur in the file.
sed -i -E \
    '/^[[:space:]]*sonar\.jdbc\.(username|password|url)[[:space:]]*=/d;
     /^[[:space:]]*sonar\.web\.(host|port|javaOpts)[[:space:]]*=/d;
     /^[[:space:]]*sonar\.(ce|search)\.javaOpts[[:space:]]*=/d;
     /^[[:space:]]*sonar\.path\.(data|temp)[[:space:]]*=/d' \
    "${SONAR_CONF}"

cat >> "${SONAR_CONF}" <<PROPERTIES

# BEGIN LOCALHELP CONFIGURATION
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
# END LOCALHELP CONFIGURATION
PROPERTIES

chown -R "${SONAR_USER}:${SONAR_USER}" "${SONAR_DIR}"
chown -h "${SONAR_USER}:${SONAR_USER}" "${SONAR_HOME}"
chown root:root "${SONAR_CONF}"
chmod 640 "${SONAR_CONF}"

# 8. Configure the SonarQube systemd service.
echo "[8/10] Configuring systemd..."

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

# 9. Configure Nginx reverse proxy.
echo "[9/10] Configuring Nginx..."

cat > /etc/nginx/conf.d/sonarqube.conf <<'NGINX'
server {
    listen 80;
    server_name sonar.localhelp.store;

    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 60s;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
NGINX

nginx -t
systemctl enable --now nginx
systemctl reload nginx

# 10. Start SonarQube and wait for readiness.
echo "[10/10] Starting SonarQube..."

systemctl daemon-reload
systemctl enable sonarqube
systemctl restart sonarqube

READY=false

for attempt in $(seq 1 60); do
    STATUS="$(curl -fsS --max-time 5 \
        http://127.0.0.1:9000/api/system/status 2>/dev/null || true)"

    if printf '%s' "${STATUS}" |
        grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"'; then
        READY=true
        break
    fi

    echo "Waiting for SonarQube (${attempt}/60)..."
    sleep 10
done

if [[ "${READY}" != "true" ]]; then
    echo "ERROR: SonarQube did not become healthy."
    echo "----- systemd status -----"
    systemctl status sonarqube --no-pager -l || true
    echo "----- SonarQube log -----"
    tail -n 80 "${SONAR_HOME}/logs/sonar.log" || true
    echo "----- Web log -----"
    tail -n 80 "${SONAR_HOME}/logs/web.log" || true
    echo "----- Compute Engine log -----"
    tail -n 80 "${SONAR_HOME}/logs/ce.log" || true
    exit 1
fi

echo
echo "============================================================"
echo "SUCCESS: SonarQube is operational."
echo "URL: http://${DOMAIN}"
echo "Local health: ${STATUS}"
echo "Service: systemctl status sonarqube"
echo "Logs: /var/log/sonarqube-install.log"
echo "Database password file: ${DB_ENV} (root-only)"
echo "============================================================"
