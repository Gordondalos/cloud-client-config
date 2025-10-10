#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# 0) Локаторы путей
# -----------------------------
# Абсолютный путь к директории скрипта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Корень проекта — на каталог выше скрипта (там лежит docker-compose.yml и .env)
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "Не найден compose-файл: ${COMPOSE_FILE}" >&2
  exit 1
fi

# Всегда работаем из корня репо, чтобы относительные пути в compose (./scripts, ./mysql.cnf и т.п.) были корректны
cd "${ROOT_DIR}"

# -----------------------------
# 1) Загрузка .env из КОРНЯ
# -----------------------------
if [ -f .env ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)
fi

: "${BD_PROXY_ID:?BD_PROXY_ID is required in .env}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required in .env}"

DB_CONTAINER="db-${BD_PROXY_ID}"
APP_CONTAINER="bd-proxy-${BD_PROXY_ID}"
HOST_DB_PORT="${HOST_DB_PORT:-33${BD_PROXY_ID}}"   # наружный порт на хосте — только для инфо
DB_HOST="127.0.0.1"

# -----------------------------
# 2) docker compose v2
# -----------------------------
COMPOSE="docker compose"
# изолируем ресурсы клиента
export COMPOSE_PROJECT_NAME="client-${BD_PROXY_ID}"

# -----------------------------
# 3) Поднять БД
# -----------------------------
# Если есть скрипт генерации compose — попробуем молча
npm run generate-docker-compose >/dev/null 2>&1 || ./generate-compose.sh >/dev/null 2>&1 || true

# Стартуем только БД по указанному compose-файлу
$COMPOSE -f "${COMPOSE_FILE}" up -d "${DB_CONTAINER}"

echo "Ожидание готовности ${DB_CONTAINER} (MySQL)..."
MAX_PING_RETRIES=60
PING_SLEEP=3
PING_OK=0

for i in $(seq 1 $MAX_PING_RETRIES); do
  if docker exec "${DB_CONTAINER}" mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; then
    PING_OK=1
    break
  fi
  sleep "${PING_SLEEP}"
done

# Если ping не помог — ждём по логам "ready for connections"
if [ "$PING_OK" -ne 1 ]; then
  echo "mysqladmin ping не дождался готовности, проверяем логи..."
  MAX_LOG_WAIT=120
  while [ $MAX_LOG_WAIT -gt 0 ]; do
    if docker logs "${DB_CONTAINER}" 2>&1 | grep -q "ready for connections"; then
      break
    fi
    sleep 2
    MAX_LOG_WAIT=$((MAX_LOG_WAIT-2))
  done
fi

# Финальная проверка
if ! docker exec "${DB_CONTAINER}" sh -lc "mysql -N -uroot -p\"${MYSQL_ROOT_PASSWORD}\" -e 'SELECT 1' >/dev/null 2>&1"; then
  echo "Ошибка: MySQL в контейнере ${DB_CONTAINER} так и не стал доступен." >&2
  docker logs "${DB_CONTAINER}" | tail -n 200 >&2 || true
  exit 1
fi

# -----------------------------
# 4) Инфо
# -----------------------------
cat <<EOF

Будут инициализированы базы данных: fnt, fnt_log
Полные реквизиты подключения (хостовая машина):
  Host:      ${DB_HOST}
  Port:      ${HOST_DB_PORT}
  User:      root
  Password:  ${MYSQL_ROOT_PASSWORD}
  Container: ${DB_CONTAINER}

EOF

# -----------------------------
# 5) Дроп/создание БД
# -----------------------------
docker exec -i "${DB_CONTAINER}" sh -c "mysql -uroot -p\"${MYSQL_ROOT_PASSWORD}\"" <<'SQL'
DROP DATABASE IF EXISTS `fnt`;
CREATE DATABASE IF NOT EXISTS `fnt` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
DROP DATABASE IF EXISTS `fnt_log`;
CREATE DATABASE IF NOT EXISTS `fnt_log` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
SQL

# -----------------------------
# 6) Импорт SQL
# -----------------------------
docker exec -i "${DB_CONTAINER}" sh -s <<'SH'
set -e
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < /docker-entrypoint-initdb.d/01init.sql

# Основной дамп (если есть)
if [ -f /docker-entrypoint-initdb.d/2024-01-01T12:56:53.fnt.sql ]; then
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/2024-01-01T12:56:53.fnt.sql
fi

# Доп. скрипты (если присутствуют)
[ -f /docker-entrypoint-initdb.d/init_paper_print.sql ]       && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt     < /docker-entrypoint-initdb.d/init_paper_print.sql
[ -f /docker-entrypoint-initdb.d/init_business_day.sql ]      && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt     < /docker-entrypoint-initdb.d/init_business_day.sql
[ -f /docker-entrypoint-initdb.d/init_bug_report.sql ]        && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt     < /docker-entrypoint-initdb.d/init_bug_report.sql
[ -f /docker-entrypoint-initdb.d/init_fnt_log.sql ]           && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt_log < /docker-entrypoint-initdb.d/init_fnt_log.sql
[ -f /docker-entrypoint-initdb.d/patch_add_code_columns.sql ] && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt     < /docker-entrypoint-initdb.d/patch_add_code_columns.sql
SH

# -----------------------------
# 7) Очистка/подготовка данных (оставь свою бизнес-логику)
# -----------------------------
CLEANUP_SQL=$(cat <<'EOSQL'
-- Здесь может быть твой полный блок очистки.
USE fnt;
SET FOREIGN_KEY_CHECKS=0;
-- TRUNCATE TABLE cashbox_actions;
-- TRUNCATE TABLE tickets;
SET FOREIGN_KEY_CHECKS=1;
EOSQL
)
printf "%s" "$CLEANUP_SQL" | docker exec -i "${DB_CONTAINER}" sh -lc '
  set -e
  cat > /tmp/cleanup.sql
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /tmp/cleanup.sql
  rm -f /tmp/cleanup.sql
'

# Патчим логин первой записи под номер клиента
LOGIN="gordondalos${BD_PROXY_ID}"
docker exec -i "${DB_CONTAINER}" sh -lc "mysql -uroot -p\"${MYSQL_ROOT_PASSWORD}\" -e \"UPDATE fnt.users u JOIN (SELECT id FROM (SELECT MIN(id) AS id FROM fnt.users) t) m ON m.id = u.id SET u.login='${LOGIN}';\""

echo "Инициализация баз данных завершена."

# -----------------------------
# 8) Поднять приложение и запустить миграции
# -----------------------------
$COMPOSE -f "${COMPOSE_FILE}" up -d "${APP_CONTAINER}"

echo "Ожидание готовности ${APP_CONTAINER}..."
MAX_RETRIES=60
RETRY_INTERVAL=3
i=0
until docker ps --filter "name=${APP_CONTAINER}" --filter "status=running" | grep -q "${APP_CONTAINER}"; do
  if [ $i -ge $MAX_RETRIES ]; then
    echo "Контейнер ${APP_CONTAINER} не стартовал вовремя" >&2
    docker logs "${APP_CONTAINER}" | tail -n 200 >&2 || true
    exit 1
  fi
  sleep $RETRY_INTERVAL
  ((i++))
done

echo "Запуск миграций внутри ${APP_CONTAINER}..."
docker exec -i "${APP_CONTAINER}" /bin/sh -c 'export TYPEORM_MIGRATIONS_TRANSACTION_MODE=none; npm run migrate-run -- --transaction none' || true

echo "Готово."
