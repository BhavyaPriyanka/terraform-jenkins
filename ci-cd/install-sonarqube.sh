#!/bin/bash
set -Eeuo pipefail
umask 077

exec > >(tee -a /var/log/sonarqube-install.log) 2>&1

trap 'rc=$?; echo "ERROR: line ${LINENO}, exit code ${rc}"; exit "$rc"' ERR

# ---------- Configuration ----------
SONAR_VERSION="26.10.0.133078"
SONAR_ZIP="sonarqube-${SONAR_VERSION}.zip"
SONAR_URL="https://binaries.sonarsource.com/Distribution/sonarqube/${SONAR_ZIP}"

SONAR_HOME="/opt/sonarqube"
SONAR_USER="sonar"

DB_NAME="sonarqube"
DB_USER="sonar"
DB_PASSWORD_FILE="/root/.sonarqube-db-password"
PGDATA="/var/lib/pgsql/data"

# ---------- Preflight ----------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    exit 1
fi

if [[ ! -f /etc/os-release ]] || ! grep -q 'Amazon Linux' /etc/os-release; then
    echo "ERROR: This script expects Amazon Linux."
    exit 1
fi

echo "=== 1. Installing required packages ==="

dnf install -y \
    java-21-amazon-corretto-headless \
    curl unzip openssl \
    postgresql15 postgresql15-server

echo "=== 2. Checking Java ==="

command -v java
java -version

JAVA_BIN="$(readlink -f "$(command -v java)")"
JAVA_HOME="${JAVA_BIN%/bin/java}"

# ---------- PostgreSQL ----------
echo "=== 3. Initializing PostgreSQL ==="

if [[ ! -s "${PGDATA}/PG_VERSION" ]]; then
    install -d -o postgres -g postgres /var/lib/pgsql
    runuser -u postgres -- /usr/bin/initdb -D "$PGDATA"
fi

systemctl enable --now postgresql

echo "=== 4. Creating database credentials ==="

if [[ ! -s "$DB_PASSWORD_FILE" ]]; then
    openssl rand -hex 32 > "$DB_PASSWORD_FILE"
fi

chmod 600 "$DB_PASSWORD_FILE"
DB_PASSWORD="$(cat "$DB_PASSWORD_FILE")"

# Add explicit password authentication for local TCP connections.
PG_HBA="${PGDATA}/pg_hba.conf"

if ! grep -qE '^host[[:space:]]+sonarqube[[:space:]]+sonar[[:space:]]+127\.0\.0\.1/32' "$PG_HBA"; then
    sed -i '1i host sonarqube sonar 127.0.0.1/32 scram-sha-256' "$PG_HBA"
fi

if ! grep -qE '^host[[:space:]]+sonarqube[[:space:]]+sonar[[:space:]]+::1/128' "$PG_HBA"; then
    sed -i '1i host sonarqube sonar ::1/128 scram-sha-256' "$PG_HBA"
fi

systemctl reload postgresql

# The generated password is hexadecimal, so it is safe in this SQL literal.
if runuser -u postgres -- psql -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
        -c "ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';"
else
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
        -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASSWORD}';"
fi

if runuser -u postgres -- psql -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
        -c "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};"
else
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
fi

echo "=== 5. Testing database authentication ==="

PGPASSWORD="$DB_PASSWORD" psql \
    -h 127.0.0.1 \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 \
    -c 'SELECT current_user, current_database();'

unset PGPASSWORD

# ---------- SonarQube download ----------
echo "=== 6. Downloading SonarQube ==="

if [[ ! -x "${SONAR_HOME}/bin/linux-x86-64/sonar.sh" ]]; then
    if [[ -e "$SONAR_HOME" ]]; then
        echo "ERROR: ${SONAR_HOME} exists but is incomplete."
        echo "Inspect it before removing or replacing anything."
        exit 1
    fi

    TMP_DIR="$(mktemp -d)"
    trap 'rc=$?; rm -rf "${TMP_DIR:-}"; echo "ERROR: line ${LINENO}, exit code ${rc}"; exit "$rc"' ERR

    curl --fail --show-error --location \
        --retry 5 --retry-all-errors --retry-delay 5 \
        "$SONAR_URL" -o "${TMP_DIR}/${SONAR_ZIP}"

    unzip -tq "${TMP_DIR}/${SONAR_ZIP}"
    unzip -q "${TMP_DIR}/${SONAR_ZIP}" -d "$TMP_DIR"

    mv "${TMP_DIR}/sonarqube-${SONAR_VERSION}" "$SONAR_HOME"
    rm -rf "$TMP_DIR"
    trap 'rc=$?; echo "ERROR: line ${LINENO}, exit code ${rc}"; exit "$rc"' ERR
fi

# ---------- Service account ----------
echo "=== 7. Configuring service account ==="

if ! id "$SONAR_USER" >/dev/null 2>&1; then
    useradd --system --create-home \
        --home-dir /home/sonar \
        --shell /sbin/nologin "$SONAR_USER"
fi

chown -R "${SONAR_USER}:${SONAR_USER}" "$SONAR_HOME"

# ---------- SonarQube configuration ----------
echo "=== 8. Configuring database connection ==="

CONF="${SONAR_HOME}/conf/sonar.properties"

set_property() {
    local key="$1"
    local value="$2"
    local tmp
    tmp="$(mktemp)"

    awk -v key="$key" -v value="$value" '
        BEGIN { done=0 }
        {
            line=$0
            sub(/^[[:space:]#]*/, "", line)
            split(line, parts, "=")

            if (parts[1] == key) {
                if (!done) print key "=" value
                done=1
                next
            }
            print
        }
        END {
            if (!done) print key "=" value
        }
    ' "$CONF" > "$tmp"

    cat "$tmp" > "$CONF"
    rm -f "$tmp"
}

set_property "sonar.jdbc.username" "$DB_USER"
set_property "sonar.jdbc.password" "$DB_PASSWORD"
set_property "sonar.jdbc.url" \
    "jdbc:postgresql://127.0.0.1:5432/${DB_NAME}"
set_property "sonar.web.host" "0.0.0.0"
set_property "sonar.web.port" "9000"

chown "${SONAR_USER}:${SONAR_USER}" "$CONF"
chmod 600 "$CONF"

# ---------- Elasticsearch kernel requirements ----------
echo "=== 9. Applying kernel settings ==="

cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF

sysctl --system

# ---------- systemd ----------
echo "=== 10. Creating systemd service ==="

cat > /etc/systemd/system/sonarqube.service <<EOF
[Unit]
Description=SonarQube Server
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=forking
User=${SONAR_USER}
Group=${SONAR_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
WorkingDirectory=${SONAR_HOME}
ExecStart=${SONAR_HOME}/bin/linux-x86-64/sonar.sh start
ExecStop=${SONAR_HOME}/bin/linux-x86-64/sonar.sh stop
LimitNOFILE=131072
LimitNPROC=8192
Restart=on-failure
RestartSec=10
TimeoutStartSec=300
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sonarqube

echo "=== 11. Starting SonarQube ==="

systemctl restart sonarqube

echo "=== 12. Waiting for application health ==="

for attempt in $(seq 1 60); do
    STATUS="$(curl --silent --show-error --max-time 5 \
        http://127.0.0.1:9000/api/system/status 2>/dev/null || true)"

    if echo "$STATUS" | grep -qE '"status"[[:space:]]*:[[:space:]]*"UP"'; then
        echo "SUCCESS: SonarQube health status is UP."
        systemctl status sonarqube --no-pager -l
        echo "URL: http://<EC2-IP>:9000"
        echo "Database password is stored in ${DB_PASSWORD_FILE}"
        exit 0
    fi

    echo "Waiting for SonarQube (${attempt}/60): ${STATUS:-no response}"
    sleep 5
done

echo "ERROR: SonarQube did not become healthy within 5 minutes."
systemctl status sonarqube --no-pager -l || true
tail -n 100 "${SONAR_HOME}/logs/web.log" || true
tail -n 100 "${SONAR_HOME}/logs/sonar.log" || true
tail -n 100 "${SONAR_HOME}/logs/es.log" || true
exit 1
