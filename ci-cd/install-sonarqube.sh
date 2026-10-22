#!/bin/bash
set -Eeuo pipefail

exec > >(tee -a /var/log/sonarqube-install.log) 2>&1

trap 'rc=$?; echo "ERROR: Installation failed at line ${LINENO}, exit code ${rc}"; exit "$rc"' ERR

SONAR_VERSION="26.10.0.133078"
SONAR_ZIP="sonarqube-${SONAR_VERSION}.zip"
SONAR_URL="https://binaries.sonarsource.com/Distribution/sonarqube/${SONAR_ZIP}"

SONAR_HOME="/opt/sonarqube"
SONAR_USER="sonarqube"
DB_NAME="sonarqube"
DB_USER="sonar"
DB_PASSWORD_FILE="/root/.sonarqube-db-password"

echo "=== 1. Installing required packages ==="

for attempt in 1 2 3 4 5; do
    if dnf install -y \
        java-21-amazon-corretto-devel \
        curl wget unzip \
        postgresql15 postgresql15-server; then
        break
    fi

    if [ "$attempt" -eq 5 ]; then
        echo "ERROR: Package installation failed after 5 attempts."
        echo "Check EC2 subnet routing, NACL, DNS and repository access."
        exit 1
    fi

    echo "Package installation attempt ${attempt} failed; retrying..."
    sleep 15
done

echo "=== 2. Checking Java ==="

JAVA_BIN="$(readlink -f "$(command -v java)")"
JAVA_HOME="${JAVA_BIN%/bin/java}"
export JAVA_HOME
java -version

echo "=== 3. Initializing PostgreSQL ==="

if [ ! -s /var/lib/pgsql/data/PG_VERSION ]; then
    postgresql-setup --initdb
fi

systemctl enable --now postgresql

PG_HBA="/var/lib/pgsql/data/pg_hba.conf"

# Add specific password-authentication rules before general localhost rules.
if ! grep -qE '^host[[:space:]]+sonarqube[[:space:]]+sonar[[:space:]]+127\.0\.0\.1/32' "$PG_HBA"; then
    sed -i '1i host sonarqube sonar 127.0.0.1/32 scram-sha-256' "$PG_HBA"
fi

if ! grep -qE '^host[[:space:]]+sonarqube[[:space:]]+sonar[[:space:]]+::1/128' "$PG_HBA"; then
    sed -i '1i host sonarqube sonar ::1/128 scram-sha-256' "$PG_HBA"
fi

systemctl reload postgresql

echo "=== 4. Creating database credentials ==="

# Generate a strong password once and reuse it on subsequent runs.
if [ ! -s "$DB_PASSWORD_FILE" ]; then
    umask 077
    openssl rand -hex 32 > "$DB_PASSWORD_FILE"
fi

chmod 600 "$DB_PASSWORD_FILE"
DB_PASSWORD="$(cat "$DB_PASSWORD_FILE")"

if sudo -u postgres psql -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 \
        -c "ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';"
else
    sudo -u postgres psql -v ON_ERROR_STOP=1 \
        -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASSWORD}';"
fi

if sudo -u postgres psql -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 \
        -c "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};"
else
    sudo -u postgres psql -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
fi

echo "=== 5. Verifying database authentication ==="

PGPASSWORD="$DB_PASSWORD" psql \
    -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 \
    -c 'SELECT current_user, current_database();'

unset PGPASSWORD

echo "=== 6. Downloading SonarQube ==="

if [ ! -x "${SONAR_HOME}/bin/linux-x86-64/sonar.sh" ]; then
    TMP_DIR="$(mktemp -d)"
    trap 'rc=$?; rm -rf "${TMP_DIR:-}"; echo "ERROR: Installation failed at line ${LINENO}, exit code ${rc}"; exit "$rc"' ERR

    curl --fail --show-error --location \
        --retry 5 --retry-all-errors --retry-delay 5 \
        "$SONAR_URL" -o "${TMP_DIR}/${SONAR_ZIP}"

    unzip -tq "${TMP_DIR}/${SONAR_ZIP}"
    unzip -q "${TMP_DIR}/${SONAR_ZIP}" -d "$TMP_DIR"

    rm -rf "$SONAR_HOME"
    mv "${TMP_DIR}/sonarqube-${SONAR_VERSION}" "$SONAR_HOME"
    rm -rf "$TMP_DIR"
    trap 'rc=$?; echo "ERROR: Installation failed at line ${LINENO}, exit code ${rc}"; exit "$rc"' ERR
fi

echo "=== 7. Creating the SonarQube service account ==="

if ! id "$SONAR_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$SONAR_HOME" \
        --shell /sbin/nologin "$SONAR_USER"
fi

chown -R "${SONAR_USER}:${SONAR_USER}" "$SONAR_HOME"

echo "=== 8. Configuring SonarQube ==="

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
    }' "$CONF" > "$tmp"

    cat "$tmp" > "$CONF"
    rm -f "$tmp"
}

set_property "sonar.jdbc.username" "$DB_USER"
set_property "sonar.jdbc.password" "$DB_PASSWORD"
set_property "sonar.jdbc.url" "jdbc:postgresql://127.0.0.1:5432/${DB_NAME}"
set_property "sonar.web.host" "0.0.0.0"
set_property "sonar.web.port" "9000"

chown "${SONAR_USER}:${SONAR_USER}" "$CONF"
chmod 600 "$CONF"

echo "=== 9. Applying Linux kernel settings ==="

cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF

sysctl --system

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
ExecStart=${SONAR_HOME}/bin/linux-x86-64/sonar.sh start
ExecStop=${SONAR_HOME}/bin/linux-x86-64/sonar.sh stop
LimitNOFILE=131072
LimitNPROC=8192
Restart=on-failure
RestartSec=10
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sonarqube
systemctl restart sonarqube

echo "=== 11. Waiting for the web server ==="

for attempt in $(seq 1 60); do
    if curl --silent --fail \
        http://127.0.0.1:9000/ \
        -o /dev/null; then
        echo "SUCCESS: SonarQube is responding on port 9000."
        systemctl status sonarqube --no-pager -l
        exit 0
    fi

    sleep 5
done

echo "ERROR: SonarQube did not respond within 5 minutes."
systemctl status sonarqube --no-pager -l || true
tail -n 100 "${SONAR_HOME}/logs/web.log" || true
tail -n 100 "${SONAR_HOME}/logs/sonar.log" || true
exit 1
