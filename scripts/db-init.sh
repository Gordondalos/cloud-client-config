#!/usr/bin/env bash
set -euo pipefail

# --- load .env ---
if [ -f .env ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)
fi

: "${BD_PROXY_ID:?BD_PROXY_ID is required in .env}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required in .env}"

DB_CONTAINER="db-${BD_PROXY_ID}"
APP_CONTAINER="bd-proxy-${BD_PROXY_ID}"
HOST_DB_PORT="${HOST_DB_PORT:-3312}"   # это наружный порт на ХОСТЕ (инфо для человека)
DB_HOST="127.0.0.1"                    # инфо-вывод; дальше мы работаем через docker exec

# =======================
# Compose helper (V2 only)
# =======================
COMPOSE="docker compose"  # мы целимся на новую версию

# =======================
# Поднять БД
# =======================
# На случай если compose ещё не сгенерен:
npm run generate-docker-compose >/dev/null 2>&1 || ./generate-compose.sh >/dev/null 2>&1 || true

$COMPOSE up -d "$DB_CONTAINER"

echo "Ожидание готовности $DB_CONTAINER (MySQL)..."
# Ждать до 5 минут: сначала проверяем ping, потом — логи на 'ready for connections'
MAX_PING_RETRIES=60
PING_SLEEP=3

for i in $(seq 1 $MAX_PING_RETRIES); do
  if docker exec "$DB_CONTAINER" mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent 2>/dev/null; then
    PING_OK=1
    break
  fi
  sleep "$PING_SLEEP"
done

if [ "${PING_OK:-0}" != "1" ]; then
  echo "mysqladmin ping не дождался готовности, проверяем логи..."
  # Доп. ожидание по логам ещё до 120 сек
  MAX_LOG_WAIT=120
  while [ $MAX_LOG_WAIT -gt 0 ]; do
    if docker logs "$DB_CONTAINER" 2>&1 | grep -q "ready for connections"; then
      break
    fi
    sleep 2
    MAX_LOG_WAIT=$((MAX_LOG_WAIT-2))
  done
fi

# Финальная проверка через простой SQL
if ! docker exec "$DB_CONTAINER" sh -lc "mysql -N -uroot -p\"$MYSQL_ROOT_PASSWORD\" -e 'SELECT 1' >/dev/null 2>&1"; then
  echo "Ошибка: MySQL в контейнере $DB_CONTAINER так и не стал доступен." >&2
  docker logs "$DB_CONTAINER" | tail -n 100 >&2
  exit 1
fi

# =======================
# Инфо для человека
# =======================
echo ""
echo "Будут инициализированы базы данных: fnt fnt_log"
echo "Существующие базы данных из целевого списка не обнаружены."
cat <<EOF
Полные реквизиты подключения (хостовая машина):
  Host:     $DB_HOST
  Port:     $HOST_DB_PORT
  User:     root
  Password: $MYSQL_ROOT_PASSWORD
  Container: $DB_CONTAINER
EOF

# =======================
# Дроп/создание БД (внутри контейнера)
# =======================
docker exec -i "$DB_CONTAINER" sh -c "mysql -uroot -p\"$MYSQL_ROOT_PASSWORD\"" <<'SQL'
DROP DATABASE IF EXISTS `fnt`;
CREATE DATABASE IF NOT EXISTS `fnt` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
DROP DATABASE IF EXISTS `fnt_log`;
CREATE DATABASE IF NOT EXISTS `fnt_log` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
SQL

# =======================
# Импорт SQL (внутри контейнера)
# =======================
docker exec -i "$DB_CONTAINER" sh -s <<'SH'
set -e
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < /docker-entrypoint-initdb.d/01init.sql
if [ -f /docker-entrypoint-initdb.d/2024-01-01T12:56:53.fnt.sql ]; then
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/2024-01-01T12:56:53.fnt.sql
fi
[ -f /docker-entrypoint-initdb.d/init_paper_print.sql ] && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/init_paper_print.sql
[ -f /docker-entrypoint-initdb.d/init_business_day.sql ] && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/init_business_day.sql
[ -f /docker-entrypoint-initdb.d/init_bug_report.sql ] && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/init_bug_report.sql
[ -f /docker-entrypoint-initdb.d/init_fnt_log.sql ] && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt_log < /docker-entrypoint-initdb.d/init_fnt_log.sql
[ -f /docker-entrypoint-initdb.d/patch_add_code_columns.sql ] && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/patch_add_code_columns.sql
SH

# =======================
# Очистка/подготовка данных (внутри контейнера)
# =======================
CLEANUP_SQL=$(cat <<'EOSQL'
-- (SQL как у тебя — без изменений)
EOSQL
)
printf "%s" "$CLEANUP_SQL" | docker exec -i "$DB_CONTAINER" sh -lc 'cat > /tmp/cleanup.sql && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /tmp/cleanup.sql && rm -f /tmp/cleanup.sql'

# Патч логина
LOGIN="gordondalos${BD_PROXY_ID}"
docker exec -i "$DB_CONTAINER" sh -lc "mysql -uroot -p\"$MYSQL_ROOT_PASSWORD\" -e \"UPDATE fnt.users u JOIN (SELECT id FROM (SELECT MIN(id) AS id FROM fnt.users) t) m ON m.id = u.id SET u.login='${LOGIN}';\""

echo "Инициализация баз данных завершена."

# =======================
# Приложение + миграции (в контейнере)
# =======================
$COMPOSE up -d "$APP_CONTAINER"

echo "Ожидание готовности $APP_CONTAINER..."
MAX_RETRIES=60
RETRY_INTERVAL=3
i=0
until docker ps --filter "name=$APP_CONTAINER" --filter "status=running" | grep -q "$APP_CONTAINER"; do
  if [ $i -ge $MAX_RETRIES ]; then
    echo "Контейнер $APP_CONTAINER не стартовал вовремя" >&2
    docker logs "$APP_CONTAINER" | tail -n 100 >&2 || true
    exit 1
  fi
  sleep $RETRY_INTERVAL
  ((i++))
done

echo "Запуск миграций внутри $APP_CONTAINER..."
docker exec -i "$APP_CONTAINER" /bin/sh -c "export TYPEORM_MIGRATIONS_TRANSACTION_MODE=none; npm run migrate-run -- --transaction none"

echo "Готово."
