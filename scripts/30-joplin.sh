#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
ensure_dirs

JOPLIN_DIR="${STACK_DIR}/docker/joplin"
JOPLIN_ENV="${STATE_DIR}/joplin.env"
JOPLIN_COMPOSE="${JOPLIN_DIR}/compose.yml"

JOPLIN_PORT="22300"
POSTGRES_IMAGE="postgres:16"
JOPLIN_IMAGE="joplin/server:latest"

mkdir -p "${JOPLIN_DIR}/postgres-data"
mkdir -p "$(dirname "${JOPLIN_ENV}")"

chmod 700 "${JOPLIN_DIR}"
chmod 700 "${JOPLIN_DIR}/postgres-data"

# Reuse an existing password on re-runs.
if [[ -f "${JOPLIN_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${JOPLIN_ENV}"

    if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
        echo "ERROR: ${JOPLIN_ENV} exists but POSTGRES_PASSWORD is missing."
        exit 1
    fi

    echo "Existing Joplin PostgreSQL password found; reusing it."

else
    echo
    echo "Joplin Server PostgreSQL configuration"
    echo

    read -r -p \
        "Do you want to specify your own Joplin PostgreSQL password? [y/N]: " \
        USE_CUSTOM_PASSWORD

    case "${USE_CUSTOM_PASSWORD}" in
        y|Y|yes|YES)
            while true; do
                read -r -s -p "Enter PostgreSQL password: " POSTGRES_PASSWORD
                echo
                read -r -s -p "Confirm PostgreSQL password: " POSTGRES_PASSWORD_CONFIRM
                echo

                if [[ -z "${POSTGRES_PASSWORD}" ]]; then
                    echo "Password cannot be empty."
                    continue
                fi

                if [[ ! "${POSTGRES_PASSWORD}" =~ ^[A-Za-z0-9._@%+=:,/-]+$ ]]; then
                    echo "Password contains unsupported characters."
                    echo "Use only letters, numbers and . _ @ % + = : , / -"
                    continue
                fi

                if [[ "${POSTGRES_PASSWORD}" != "${POSTGRES_PASSWORD_CONFIRM}" ]]; then
                    echo "Passwords do not match. Please try again."
                    continue
                fi

                break
            done
            ;;

        *)
            echo "Generating a random PostgreSQL password..."
            POSTGRES_PASSWORD="$(openssl rand -hex 32)"
            ;;
    esac

    cat > "${JOPLIN_ENV}" <<EOF
    APP_BASE_URL=https://${JOPLIN_DOMAIN}
    APP_PORT=${JOPLIN_PORT}

    DB_CLIENT=pg
    POSTGRES_HOST=joplin-postgres
    POSTGRES_PORT=5432
    POSTGRES_DATABASE=joplin
    POSTGRES_DB=joplin
    POSTGRES_USER=joplin
    POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
EOF

    chmod 600 "${JOPLIN_ENV}"

    echo
    echo "Joplin PostgreSQL credentials saved to:"
    echo "  ${JOPLIN_ENV}"
    echo
fi

cat > "${JOPLIN_COMPOSE}" <<'EOF'
services:
  joplin-postgres:
    image: postgres:16
    container_name: joplin-postgres
    restart: unless-stopped
    env_file:
      - /etc/fedora-server-setup/joplin.env
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "pg_isready -U joplin -d joplin"
        ]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 10s

  joplin:
    image: joplin/server:latest
    container_name: joplin
    restart: unless-stopped
    depends_on:
      joplin-postgres:
        condition: service_healthy
    env_file:
      - /etc/fedora-server-setup/joplin.env
    ports:
      - "127.0.0.1:22300:22300"
EOF

chmod 600 "${JOPLIN_COMPOSE}"

echo "Pulling Joplin images..."
docker compose \
    -f "${JOPLIN_COMPOSE}" \
    pull

echo "Starting Joplin Server..."
docker compose \
    -f "${JOPLIN_COMPOSE}" \
    up -d

echo
echo "Joplin Server containers started."
echo
echo "Joplin URL: https://${JOPLIN_DOMAIN}"
echo