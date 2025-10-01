#!/usr/bin/env bash
set -euo pipefail

# Initialize MySQL databases and apply SQL scripts inside the DB container,
# then run application migrations inside bd-proxy-${BD_PROXY_ID} container.
# Requirements: BD_PROXY_ID and MYSQL_ROOT_PASSWORD must be set in .env (used by docker-compose)

# Load .env if present to export variables
if [ -f .env ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)
fi

: "${BD_PROXY_ID:?BD_PROXY_ID is required in .env}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required in .env}"

DB_CONTAINER="db-${BD_PROXY_ID}"
APP_CONTAINER="bd-proxy-${BD_PROXY_ID}"
HOST_DB_PORT="${HOST_DB_PORT:-3312}"
DB_HOST="127.0.0.1"
DB_USER="root"
DB_PASS="$MYSQL_ROOT_PASSWORD"

# Ensure compose is rendered and DB container is up
npm run generate-docker-compose >/dev/null 2>&1 || ./generate-compose.sh >/dev/null 2>&1 || true

# Start only the DB first to run checks and init scripts
docker compose up -d "$DB_CONTAINER"

echo "Ожидание готовности $DB_CONTAINER (MySQL)..."
for i in {1..30}; do
  if docker exec "$DB_CONTAINER" mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent; then
    break
  fi
  sleep 2
  if [ "$i" -eq 30 ]; then
    echo "Ошибка: MySQL не стал готов вовремя" >&2
    exit 1
  fi
done

# Determine which databases exist
TARGET_DBS=("fnt" "fnt_log" "license_db")
EXISTING_DBS=()
for db in "${TARGET_DBS[@]}"; do
  if docker exec "$DB_CONTAINER" sh -lc "mysql -N -uroot -p'$MYSQL_ROOT_PASSWORD' -e \"SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$db'\" | grep -qx '$db'"; then
    EXISTING_DBS+=("$db")
  fi
done

# Print full credentials and what will be affected
echo "";
echo "Будут инициализированы базы данных: ${TARGET_DBS[*]}";
if [ ${#EXISTING_DBS[@]} -gt 0 ]; then
  echo "Найдены существующие базы (будут УДАЛЕНЫ и созданы заново): ${EXISTING_DBS[*]}";
else
  echo "Существующие базы данных из целевого списка не обнаружены.";
fi

cat <<EOF
Полные реквизиты подключения (хостовая машина):
  Host:     $DB_HOST
  Port:     $HOST_DB_PORT
  User:     $DB_USER
  Password: $DB_PASS
  Container: $DB_CONTAINER
EOF

# Ask for confirmation clearly as this will wipe data
if [ "${YES:-}" != "1" ]; then
  echo
  echo "ВНИМАНИЕ: выполнение скрипта ПОЛНОСТЬЮ УДАЛИТ данные в перечисленных базах и пересоздаст их." >&2
  printf "Вы действительно хотите продолжить? [yes/NO]: " >&2
  read -r answer || true
  case "$answer" in
    yes|y|YES|Y)
      ;;
    *)
      echo "Операция отменена пользователем." >&2
      exit 0
      ;;
  esac
fi

# Drop and (re)create databases explicitly before loading data
DROP_CREATE_SQL=""
for db in "${TARGET_DBS[@]}"; do
  DROP_CREATE_SQL+="DROP DATABASE IF EXISTS \\\\`$db\\\\`;
CREATE DATABASE IF NOT EXISTS \\\\`$db\\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;\n"
done

docker exec -i "$DB_CONTAINER" sh -s <<SH
set -e
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "${DROP_CREATE_SQL}"
SH

# Run SQL scripts in a fixed order
# 1) 01init.sql (users, grants, databases)
# 2) fnt schema dump (if present)
# 3) fnt_log schema (emptied by script itself)

docker exec -i "$DB_CONTAINER" sh -s <<'SH'
set -e
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < /docker-entrypoint-initdb.d/01init.sql
if [ -f /docker-entrypoint-initdb.d/2024-01-01T12:56:53.fnt.sql ]; then
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/2024-01-01T12:56:53.fnt.sql
fi
if [ -f /docker-entrypoint-initdb.d/init_fnt_log.sql ]; then
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt_log < /docker-entrypoint-initdb.d/init_fnt_log.sql
fi
SH

echo "Инициализация баз данных завершена."

# Start application container and run migrations
echo "Запуск $APP_CONTAINER..."
docker compose up -d "$APP_CONTAINER"

# Wait for the application container to be running before migrations
echo "Ожидание готовности $APP_CONTAINER..."
MAX_RETRIES=30
RETRY_INTERVAL=2
i=0
until docker ps --filter "name=$APP_CONTAINER" --filter "status=running" | grep -q "$APP_CONTAINER"; do
  if [ $i -ge $MAX_RETRIES ]; then
    echo "Контейнер $APP_CONTAINER не стартовал вовремя" >&2
    exit 1
  fi
  sleep $RETRY_INTERVAL
  ((i++))
done

echo "Запуск миграций внутри $APP_CONTAINER..."
docker exec -i "$APP_CONTAINER" /bin/sh -c "npm run migrate-run"

echo "Готово."