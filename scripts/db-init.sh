#!/usr/bin/env bash
set -euo pipefail

# =======================
# Загрузка .env
# =======================
if [ -f .env ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)
fi

: "${BD_PROXY_ID:?BD_PROXY_ID is required in .env}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required in .env}"

DB_CONTAINER="db-${BD_PROXY_ID}"
APP_CONTAINER="bd-proxy-${BD_PROXY_ID}"
HOST_DB_PORT="${HOST_DB_PORT:-3312}"   # наружный порт на ХОСТЕ (для информации)
DB_HOST="127.0.0.1"                    # инфо-вывод; сами команды идут через docker exec

# =======================
# Проверка docker compose (V2)
# =======================
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose (V2) не найден. Установи docker-compose-plugin и убедись, что он виден пользователю jenkins." >&2
  exit 1
fi
COMPOSE="docker compose"

# =======================
# Поднять БД
# =======================
# Если compose-файл генерируется — попробуем сгенерить (мягко, без фатала)
npm run generate-docker-compose >/dev/null 2>&1 || ./generate-compose.sh >/dev/null 2>&1 || true

$COMPOSE up -d "$DB_CONTAINER"

# =======================
# Ожидание готовности MySQL
# Пережидаем фазу временного сервера (port: 0) и ждём основной mysqld с паролем
# =======================
echo "Ожидание готовности $DB_CONTAINER (MySQL)..."

# 1) Если есть healthcheck — подождём до healthy (до 5 минут)
if docker inspect "$DB_CONTAINER" --format '{{json .State.Health.Status}}' >/dev/null 2>&1; then
  MAX_HEALTH_SECS=300
  while true; do
    STATUS="$(docker inspect "$DB_CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null || echo "")"
    if [ "$STATUS" = "healthy" ]; then
      break
    fi
    if [ "$STATUS" = "unhealthy" ]; then
      echo "MySQL health=unhealthy. Логи хвоста:"
      docker logs "$DB_CONTAINER" | tail -n 100
      exit 1
    fi
    sleep 2
    MAX_HEALTH_SECS=$((MAX_HEALTH_SECS-2))
    if [ $MAX_HEALTH_SECS -le 0 ]; then
      echo "Healthcheck не стал healthy за 5 минут — продолжаем ожидание через ping."
      break
    fi
  done
fi

# 2) Ретраи mysqladmin ping С ПАРОЛЕМ (до ~5 минут)
PING_OK=0
MAX_PING_RETRIES=150   # 150 * 2с ≈ 5 минут
for i in $(seq 1 $MAX_PING_RETRIES); do
  if docker exec "$DB_CONTAINER" sh -lc 'mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' 2>/dev/null; then
    PING_OK=1
    break
  fi
  sleep 2
done

if [ "$PING_OK" -ne 1 ]; then
  echo "Ошибка: MySQL так и не стал доступен по root-паролю. Хвост логов:"
  docker logs "$DB_CONTAINER" | tail -n 200
  exit 1
fi

# 3) Финальная проверка простым SQL
if ! docker exec "$DB_CONTAINER" sh -lc 'mysql -N -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1'; then
  echo "Ошибка: SELECT 1 не прошёл — возможно, пароль ещё не применён. Логи:"
  docker logs "$DB_CONTAINER" | tail -n 200
  exit 1
fi

# =======================
# Информация для человека
# =======================
cat <<EOF

Будут инициализированы базы данных: fnt, fnt_log

Полные реквизиты подключения (хостовая машина):
  Host:      $DB_HOST
  Port:      $HOST_DB_PORT
  User:      root
  Password:  $MYSQL_ROOT_PASSWORD
  Container: $DB_CONTAINER

EOF

# =======================
# Дроп/создание БД (внутри контейнера)
# =======================
docker exec -i "$DB_CONTAINER" sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <<'SQL'
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

# Дамп схемы fnt — если присутствует
if [ -f /docker-entrypoint-initdb.d/2024-01-01T12:56:53.fnt.sql ]; then
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/2024-01-01T12:56:53.fnt.sql
fi

# Дополнительные инициализационные скрипты, если есть
[ -f /docker-entrypoint-initdb.d/init_paper_print.sql ]   && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt     < /docker-entrypoint-initdb.d/init_paper_print.sql
[ -f /docker-entrypoint-initdb.d/init_business_day.sql ]  && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt     < /docker-entrypoint-initdb.d/init_business_day.sql
[ -f /docker-entrypoint-initdb.d/init_bug_report.sql ]    && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt     < /docker-entrypoint-initdb.d/init_bug_report.sql
[ -f /docker-entrypoint-initdb.d/init_fnt_log.sql ]       && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt_log < /docker-entrypoint-initdb.d/init_fnt_log.sql
[ -f /docker-entrypoint-initdb.d/patch_add_code_columns.sql ] && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/patch_add_code_columns.sql
SH

# =======================
# Очистка/подготовка данных (внутри контейнера)
# =======================
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
-- fallback to 1 if nulls
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
printf "%s" "$CLEANUP_SQL" | docker exec -i "$DB_CONTAINER" sh -lc 'cat > /tmp/cleanup.sql && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /tmp/cleanup.sql && rm -f /tmp/cleanup.sql'

# Патч логина под ID клиента
LOGIN="gordondalos${BD_PROXY_ID}"
docker exec -i "$DB_CONTAINER" sh -lc "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"UPDATE fnt.users u JOIN (SELECT id FROM (SELECT MIN(id) AS id FROM fnt.users) t) m ON m.id = u.id SET u.login='${LOGIN}';\""

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
docker exec -i "$APP_CONTAINER" /bin/sh -c 'export TYPEORM_MIGRATIONS_TRANSACTION_MODE=none; npm run migrate-run -- --transaction none'

echo "Готово."
