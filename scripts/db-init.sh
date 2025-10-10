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

# -----------------------
# Фаза A: ждём, пока MySQL вообще поднимется (temporary server ок)
#   1) health=healthy
#   2) mysqladmin ping БЕЗ пароля (temporary server тоже ответит)
# -----------------------
for _ in {1..180}; do
  st="$(docker inspect -f '{{.State.Health.Status}}' "${DB_CONTAINER}" 2>/dev/null || echo unknown)"
  [[ "${st}" == "healthy" ]] && break
  sleep 2
done

for _ in {1..120}; do
  if docker exec "${DB_CONTAINER}" mysqladmin ping -h localhost --silent >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# -----------------------
# Фаза B: ждём, пока ЗАРАБОТАЕТ ПАРОЛЬ (т.е. финальный сервер после init-скриптов)
#   Критерий: "SELECT 1" с root+паролем успешно.
#   Это может занять ещё 2-5 минут на больших дампах.
# -----------------------
PW_OK=0
for _ in {1..240}; do
  if docker exec "${DB_CONTAINER}" sh -lc "mysql -N -uroot -p\"${MYSQL_ROOT_PASSWORD}\" -e 'SELECT 1' >/dev/null 2>&1"; then
    PW_OK=1
    break
  fi
  sleep 2
done

if [[ "${PW_OK}" != "1" ]]; then
  echo "Ошибка: пароль root ещё не применён / финальный сервер не готов. Хвост логов:" >&2
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
# 01init.sql может создавать пользователей/гранты и т.п.
[ -f /docker-entrypoint-initdb.d/01init.sql ] && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < /docker-entrypoint-initdb.d/01init.sql || true

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

echo "Инициализация БД завершена."

# =======================
# (ОПЦИОНАЛЬНО) Очистка/подготовка данных
# Если не нужна — удали блок ниже до «Патчим логин».
# =======================
CLEANUP_SQL=$(cat <<'EOSQL'
USE fnt;

SET FOREIGN_KEY_CHECKS=0;
TRUNCATE TABLE cashbox_actions;
TRUNCATE TABLE tickets;
TRUNCATE TABLE paper_movements;
TRUNCATE TABLE clients;
SET FOREIGN_KEY_CHECKS=1;

DELETE FROM gold_price_settings;
DELETE FROM gold_sample_settings;

SET FOREIGN_KEY_CHECKS=0;
DELETE FROM users;
SET FOREIGN_KEY_CHECKS=1;

SET @region_id     = IFNULL((SELECT MIN(id) FROM region),1);
SET @issue_auth_id = IFNULL((SELECT MIN(id) FROM issue_authority),1);
SET @post_id       = IFNULL((SELECT MIN(id) FROM posts),1);

INSERT INTO users (
  name, surname, fathers_name, sex, birthdate, passport, document_issue_authority_id,
  document_issue_date, inn, address_region_id, address, phone, filial_id, login,
  password, post_id, creation_date, document_issue_authority_number, tableSettings
) VALUES (
  'Gordon', 'Dalos', 'N/A', 1, '1990-01-01 00:00:00', 'ID0000000', @issue_auth_id,
  '2010-01-01', '00000000000000', @region_id, 'N/A', '+000000000', 9, '__LOGIN_TO_PATCH__',
  '$2y$10$4bV8S8j6V8TqVJmCq2gO6e5kqYcF2m1U0t3iGz7bV8ZqFJmCq2gO6', @post_id, NOW(), 0, NULL
);

DELETE FROM filials WHERE id <> 9;

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

# Запуск миграций, если есть npm-скрипт
docker exec -i "${APP_CONTAINER}" /bin/sh -c 'command -v npm >/dev/null 2>&1 && (export TYPEORM_MIGRATIONS_TRANSACTION_MODE=none; npm run migrate-run -- --transaction none) || true' || true

echo "Готово."
