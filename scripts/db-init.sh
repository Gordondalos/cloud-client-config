#!/usr/bin/env bash
set -euo pipefail

# =======================
# Локаторы путей
# =======================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

cd "${ROOT_DIR}"

# =======================
# Загрузка .env из КОРНЯ
# =======================
if [[ -f .env ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)
fi

: "${BD_PROXY_ID:?BD_PROXY_ID is required in .env}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required in .env}"

# Порт MySQL наружу по умолчанию 33${ID} → 22=>3322, 25=>3325 и т.п.
export HOST_DB_PORT="${HOST_DB_PORT:-33${BD_PROXY_ID}}"
export COMPOSE_PROJECT_NAME="client-${BD_PROXY_ID}"

DB_CONTAINER="db-${BD_PROXY_ID}"
APP_CONTAINER="bd-proxy-${BD_PROXY_ID}"

# =======================
# docker compose v2
# =======================
COMPOSE="docker compose"

# =======================
# Генерация compose и старт БД
# =======================
if ! bash "${ROOT_DIR}/generate-compose.sh"; then
  echo "[WARN] generate-compose.sh завершился с ошибкой — продолжим, если compose уже есть…" >&2
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "Не найден ${COMPOSE_FILE} — прервали." >&2
  exit 1
fi

# Поднимаем только БД
${COMPOSE} -f "${COMPOSE_FILE}" up -d "${DB_CONTAINER}"

echo "Ожидание готовности ${DB_CONTAINER} (MySQL)…"
# 1) ждём health=healthy
for _ in {1..120}; do
  st="$(docker inspect -f '{{.State.Health.Status}}' "${DB_CONTAINER}" 2>/dev/null || echo unknown)"
  [[ "${st}" == "healthy" ]] && break
  sleep 2
done

# 2) затем mysqladmin ping
for _ in {1..60}; do
  if docker exec "${DB_CONTAINER}" mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; then
    break
  fi
  sleep 2
done

# 3) финальный SELECT
if ! docker exec "${DB_CONTAINER}" sh -lc "mysql -N -uroot -p\"${MYSQL_ROOT_PASSWORD}\" -e 'SELECT 1' >/dev/null 2>&1"; then
  echo "Ошибка: MySQL в контейнере ${DB_CONTAINER} не отвечает на SELECT. Хвост логов:" >&2
  docker logs "${DB_CONTAINER}" | tail -n 200 >&2 || true
  exit 1
fi

cat <<EOF

Будут инициализированы базы данных: fnt, fnt_log
Параметры подключения с хоста (инфо):
  Host:      127.0.0.1
  Port:      ${HOST_DB_PORT}
  User:      root
  Password:  ${MYSQL_ROOT_PASSWORD}
  Container: ${DB_CONTAINER}

EOF

# =======================
# Дроп/создание БД
# =======================
docker exec -i "${DB_CONTAINER}" sh -c "mysql -uroot -p\"${MYSQL_ROOT_PASSWORD}\"" <<'SQL'
DROP DATABASE IF EXISTS `fnt`;
CREATE DATABASE IF NOT EXISTS `fnt` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
DROP DATABASE IF EXISTS `fnt_log`;
CREATE DATABASE IF NOT EXISTS `fnt_log` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
SQL

# =======================
# Импорт SQL (по наличию)
# =======================
docker exec -i "${DB_CONTAINER}" sh -s <<'SH'
set -e
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < /docker-entrypoint-initdb.d/01init.sql || true

# дамп схемы fnt (если есть)
if [ -f /docker-entrypoint-initdb.d/2024-01-01T12:56:53.fnt.sql ]; then
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /docker-entrypoint-initdb.d/2024-01-01T12:56:53.fnt.sql
fi

# доп. необходимые таблицы/патчи для fnt
[ -f /docker-entrypoint-initdb.d/init_paper_print.sql ]       && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt     < /docker-entrypoint-initdb.d/init_paper_print.sql
[ -f /docker-entrypoint-initdb.d/init_business_day.sql ]      && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt     < /docker-entrypoint-initdb.d/init_business_day.sql
[ -f /docker-entrypoint-initdb.d/init_bug_report.sql ]        && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt     < /docker-entrypoint-initdb.d/init_bug_report.sql
[ -f /docker-entrypoint-initdb.d/patch_add_code_columns.sql ] && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt     < /docker-entrypoint-initdb.d/patch_add_code_columns.sql

# схема fnt_log (если есть)
[ -f /docker-entrypoint-initdb.d/init_fnt_log.sql ]           && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt_log < /docker-entrypoint-initdb.d/init_fnt_log.sql
SH

# =======================
# Очистка/подготовка данных (реальный SQL-блок)
# =======================
CLEANUP_SQL=$(cat <<'EOSQL'
USE fnt;

-- 1) Очистка бизнес-таблиц
SET FOREIGN_KEY_CHECKS=0;
TRUNCATE TABLE cashbox_actions;
TRUNCATE TABLE tickets;
TRUNCATE TABLE paper_movements;
TRUNCATE TABLE clients;
SET FOREIGN_KEY_CHECKS=1;

-- 2) Удаляем настройки цен/проб до пересоздания
DELETE FROM gold_price_settings;
DELETE FROM gold_sample_settings;

-- 3) Пользователи → оставляем только одну заглушку, затем пропатчим login динамически
SET FOREIGN_KEY_CHECKS=0;
DELETE FROM users;
SET FOREIGN_KEY_CHECKS=1;

-- Базовые внешние ключи (если пусто — подставим 1)
SET @region_id     = (SELECT MIN(id) FROM region);
SET @issue_auth_id = (SELECT MIN(id) FROM issue_authority);
SET @post_id       = (SELECT MIN(id) FROM posts);
SET @region_id     = IFNULL(@region_id,1);
SET @issue_auth_id = IFNULL(@issue_auth_id,1);
SET @post_id       = IFNULL(@post_id,1);

INSERT INTO users (
  name, surname, fathers_name, sex, birthdate, passport, document_issue_authority_id,
  document_issue_date, inn, address_region_id, address, phone, filial_id, login,
  password, post_id, creation_date, document_issue_authority_number, tableSettings
) VALUES (
  'Gordon', 'Dalos', 'N/A', 1, '1990-01-01 00:00:00', 'ID0000000', @issue_auth_id,
  '2010-01-01', '00000000000000', @region_id, 'N/A', '+000000000', 9, '__LOGIN_TO_PATCH__',
  '$2y$10$4bV8S8j6V8TqVJmCq2gO6e5kqYcF2m1U0t3iGz7bV8ZqFJmCq2gO6', @post_id, NOW(), 0, NULL
);

-- 4) Филиалы → оставить только центральный id=9
DELETE FROM filials WHERE id <> 9;

-- 5) Создаём по одной записи в настройках цен/проб, привязываем к вставленному пользователю
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

printf "%s" "$CLEANUP_SQL" | docker exec -i "${DB_CONTAINER}" sh -lc '
  set -e
  cat > /tmp/cleanup.sql
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" fnt < /tmp/cleanup.sql
  rm -f /tmp/cleanup.sql
'

# Патчим логин первой записи users → gordondalos${BD_PROXY_ID}
LOGIN="gordondalos${BD_PROXY_ID}"
docker exec -i "${DB_CONTAINER}" sh -lc "mysql -uroot -p\"${MYSQL_ROOT_PASSWORD}\" -e \"UPDATE fnt.users u JOIN (SELECT id FROM (SELECT MIN(id) AS id FROM fnt.users) t) m ON m.id = u.id SET u.login='${LOGIN}';\" || true"

echo "Инициализация баз данных завершена."

# =======================
# Приложение и миграции
# =======================
${COMPOSE} -f "${COMPOSE_FILE}" up -d "${APP_CONTAINER}"

echo "Ожидание готовности ${APP_CONTAINER}…"
for _ in {1..60}; do
  if docker ps --filter "name=${APP_CONTAINER}" --filter "status=running" | grep -q "${APP_CONTAINER}"; then
    break
  fi
  sleep 3
done

# Если внутри app нужны миграции — запускаем
docker exec -i "${APP_CONTAINER}" /bin/sh -c 'export TYPEORM_MIGRATIONS_TRANSACTION_MODE=none; npm run migrate-run -- --transaction none' || true

echo "Готово."
