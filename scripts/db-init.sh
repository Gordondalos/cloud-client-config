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
TARGET_DBS=("fnt" "fnt_log")
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
# Support non-interactive approval via YES environment variable (1/true/yes/y)
_yes_norm=$(printf '%s' "${YES:-}" | tr '[:upper:]' '[:lower:]')
case "$_yes_norm" in
  1|true|yes|y|да|д)
    skip_prompt=1
    ;;
  *)
    skip_prompt=0
    ;;
esac

if [ "$skip_prompt" -ne 1 ]; then
  echo
  echo "ВНИМАНИЕ: выполнение скрипта ПОЛНОСТЬЮ УДАЛИТ данные в перечисленных базах и пересоздаст их." >&2
  printf "Вы действительно хотите продолжить? [yes/NO]: " >&2

  answer=""
  # Пытаемся прочитать из /dev/tty (интерактивный ввод)
  if [ -t 0 ] && [ -r /dev/tty ]; then
    if ! read -r answer < /dev/tty; then
      answer=""
    fi
  fi
  # Если не удалось прочитать из TTY, пробуем stdin (на случай npm/pipe)
  if [ -z "$answer" ]; then
    if ! read -r answer; then
      answer=""
    fi
  fi

  # Нормализуем ввод: обрезаем пробелы и приводим к нижнему регистру
  answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case "$answer" in
    yes|y|да|д)
      ;;
    *)
      echo
      echo "Операция отменена пользователем." >&2
      echo "Подсказка: можно запустить без подтверждения, установив переменную окружения YES=1 (или YES=yes)." >&2
      exit 0
      ;;
  esac
fi

# Drop and (re)create databases explicitly before loading data
docker exec -i "$DB_CONTAINER" sh -c "mysql -uroot -p\"$MYSQL_ROOT_PASSWORD\"" <<'SQL'
DROP DATABASE IF EXISTS `fnt`;
CREATE DATABASE IF NOT EXISTS `fnt` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
DROP DATABASE IF EXISTS `fnt_log`;
CREATE DATABASE IF NOT EXISTS `fnt_log` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
SQL

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
# Ensure required auxiliary tables missing in the dump are created
if [ -f /docker-entrypoint-initdb.d/init_paper_print.sql ]; then
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/init_paper_print.sql
fi
# Minimal business_day table required by migrations that add index on (date_open)
if [ -f /docker-entrypoint-initdb.d/init_business_day.sql ]; then
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/init_business_day.sql
fi
# Create minimal bug_report table if it's absent in the dump (needed for newer migrations)
if [ -f /docker-entrypoint-initdb.d/init_bug_report.sql ]; then
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/init_bug_report.sql
fi
if [ -f /docker-entrypoint-initdb.d/init_fnt_log.sql ]; then
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt_log < /docker-entrypoint-initdb.d/init_fnt_log.sql
fi
# Apply compatibility patch to add missing `code` columns required by newer app migrations
if [ -f /docker-entrypoint-initdb.d/patch_add_code_columns.sql ]; then
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/patch_add_code_columns.sql
fi
SH

# Post-initialization data shaping for business requirements
# - Keep only one app user with login gordondalos${BD_PROXY_ID}
# - Empty cashbox_actions, tickets, clients, paper_movements
# - Keep only filial id=9
# - Keep only one row in gold_price_settings and gold_sample_settings

CLEANUP_SQL=$(cat <<'EOSQL'
-- Ensure required minimal references exist
USE fnt;

-- 1) Tickets, cashbox actions, paper movements, clients → empty
SET FOREIGN_KEY_CHECKS=0;
TRUNCATE TABLE cashbox_actions;
TRUNCATE TABLE tickets;
TRUNCATE TABLE paper_movements;
TRUNCATE TABLE clients;
SET FOREIGN_KEY_CHECKS=1;

-- 2) Gold price/sample settings → очистить перед изменениями users (FK зависит от users)
DELETE FROM gold_price_settings;
DELETE FROM gold_sample_settings;

-- 3) Users → оставить одну заглушку; будет заменён ниже динамическим логином
SET FOREIGN_KEY_CHECKS=0;
DELETE FROM users;
SET FOREIGN_KEY_CHECKS=1;
-- pick minimal valid foreign keys from lookup tables
SET @region_id = (SELECT MIN(id) FROM region);
SET @issue_auth_id = (SELECT MIN(id) FROM issue_authority);
SET @post_id = (SELECT MIN(id) FROM posts);
-- fallback to 1 if nulls (in case dumps change)
SET @region_id = IFNULL(@region_id,1);
SET @issue_auth_id = IFNULL(@issue_auth_id,1);
SET @post_id = IFNULL(@post_id,1);

INSERT INTO users (
  name, surname, fathers_name, sex, birthdate, passport, document_issue_authority_id,
  document_issue_date, inn, address_region_id, address, phone, filial_id, login,
  password, post_id, creation_date, document_issue_authority_number, tableSettings
) VALUES (
  'Gordon', 'Dalos', 'N/A', 1, '1990-01-01 00:00:00', 'ID0000000', @issue_auth_id,
  '2010-01-01', '00000000000000', @region_id, 'N/A', '+000000000', 9, '__LOGIN_TO_PATCH__',
  '$2y$10$4bV8S8j6V8TqVJmCq2gO6e5kqYcF2m1U0t3iGz7bV8ZqFJmCq2gO6', @post_id, NOW(), 0, NULL
);

-- 4) Filials → keep only id=9 (central branch)
DELETE FROM filials WHERE id <> 9;

-- 5) Gold price/sample settings → создать по одной строке
-- Use the inserted user id for ownership
SET @u := (SELECT MIN(id) FROM users);
INSERT INTO gold_price_settings (coeficient_table, user_id, date) VALUES (
  JSON_ARRAY(JSON_OBJECT('coef', 1.0, 'name', 'base')),
  @u,
  NOW()
);
INSERT INTO gold_sample_settings (sample_table, user_id, date) VALUES (
  JSON_ARRAY(JSON_OBJECT('price', '2000', 'probe', '999')),
  @u,
  NOW()
);
EOSQL
)

# Apply the cleanup SQL
printf "%s" "$CLEANUP_SQL" | docker exec -i "$DB_CONTAINER" sh -lc 'cat > /tmp/cleanup.sql && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /tmp/cleanup.sql && rm -f /tmp/cleanup.sql'

# Patch the only user's login to include BD_PROXY_ID
LOGIN="gordondalos${BD_PROXY_ID}"
# Обойти MySQL ERROR 1093: нельзя использовать целевую таблицу в подзапросе — применяем JOIN с производной таблицей
# UPDATE fnt.users u JOIN (SELECT id FROM (SELECT MIN(id) AS id FROM fnt.users) t) m ON m.id=u.id SET u.login=...
docker exec -i "$DB_CONTAINER" sh -lc "mysql -uroot -p\"$MYSQL_ROOT_PASSWORD\" -e \"UPDATE fnt.users u JOIN (SELECT id FROM (SELECT MIN(id) AS id FROM fnt.users) t) m ON m.id = u.id SET u.login='${LOGIN}';\""

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
# Запускаем миграции без транзакций, чтобы избежать ошибок RELEASE SAVEPOINT при DDL в MySQL
docker exec -i "$APP_CONTAINER" /bin/sh -c "export TYPEORM_MIGRATIONS_TRANSACTION_MODE=none; npm run migrate-run"

echo "Готово."