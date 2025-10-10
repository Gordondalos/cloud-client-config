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
DB_HOST="127.0.0.1"                    # инфо-вывод; команды идут через docker exec

# Админ-аккаунт для DDL (по умолчанию root; при желании можно переопределить в .env)
ADMIN_USER="${ADMIN_USER:-root}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$MYSQL_ROOT_PASSWORD}"

# =======================
# Проверка docker compose (V2)
# =======================
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose (V2) не найден. Установи docker-compose-plugin и дай доступ пользователю jenkins." >&2
  exit 1
fi
COMPOSE="docker compose"

# =======================
# Поднять БД (compose-файл уже должен быть сгенерен твоими скриптами)
# =======================
$COMPOSE up -d "$DB_CONTAINER"

# =======================
# Ожидание готовности MySQL (устойчивое)
# =======================
echo "Ожидание готовности $DB_CONTAINER (MySQL)..."

# 1) Ждём, что сервер вообще начнёт отвечать без пароля (фаза init часто такова)
NO_PASS_OK=0
for _ in $(seq 1 120); do # ~4 минуты
  if docker exec "$DB_CONTAINER" sh -lc 'mysqladmin ping -uroot --silent' 2>/dev/null; then
    NO_PASS_OK=1; break
  fi
  sleep 2
done

# 2) Пытаемся пинг с паролем
PASS_OK=0
for _ in $(seq 1 120); do # ещё ~4 минуты
  if docker exec "$DB_CONTAINER" sh -lc 'mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' 2>/dev/null; then
    PASS_OK=1; break
  fi
  sleep 2
done

# 3) Если без пароля пингуется, а с паролем — нет, зададим пароль и проверим ещё раз
if [ "$PASS_OK" -ne 1 ] && [ "$NO_PASS_OK" -eq 1 ]; then
  echo "root пока без пароля — задаём MYSQL_ROOT_PASSWORD…"
  docker exec -i "$DB_CONTAINER" sh -lc 'mysql -uroot <<SQL
ALTER USER '\''root'\''@'\''localhost'\'' IDENTIFIED BY '\'''"$MYSQL_ROOT_PASSWORD"''''';
ALTER USER '\''root'\''@'\''%'\''         IDENTIFIED BY '\'''"$MYSQL_ROOT_PASSWORD"''''';
FLUSH PRIVILEGES;
SQL'
  for _ in $(seq 1 60); do
    if docker exec "$DB_CONTAINER" sh -lc 'mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' 2>/dev/null; then
      PASS_OK=1; break
    fi
    sleep 2
  done
fi

# 4) Финальная проверка SELECT 1 с паролем
if [ "$PASS_OK" -ne 1 ] || \
   ! docker exec "$DB_CONTAINER" sh -lc 'mysql -N -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1'; then
  echo "MySQL так и не стал доступен по root-паролю. Хвост логов:" >&2
  docker logs "$DB_CONTAINER" | tail -n 200 >&2
  exit 1
fi

# Если хотим работать не под root — проверим/подготовим ADMIN_USER
if [ "$ADMIN_USER" != "root" ]; then
  echo "Проверяем наличие/права $ADMIN_USER…"
  docker exec -i "$DB_CONTAINER" sh -lc 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "
CREATE USER IF NOT EXISTS '\'''"$ADMIN_USER"\"'\''@'\''%'\'' IDENTIFIED BY '\'''"$ADMIN_PASSWORD"\"'\'';
GRANT ALL PRIVILEGES ON *.* TO '\'''"$ADMIN_USER"\"'\''@'\''%'\'' WITH GRANT OPTION;
FLUSH PRIVILEGES;
"'
fi

mysql_exec() {
  docker exec -i "$DB_CONTAINER" sh -lc "mysql -u\"$ADMIN_USER\" -p\"$ADMIN_PASSWORD\" \$1"
}

# =======================
# Информация
# =======================
cat <<EOF

Будут инициализированы базы данных: fnt, fnt_log

Полные реквизиты подключения (хостовая машина):
  Host:      $DB_HOST
  Port:      $HOST_DB_PORT
  User:      $ADMIN_USER
  Password:  (скрыт)
  Container: $DB_CONTAINER

EOF

# =======================
# Дроп/создание БД
# =======================
mysql_exec "" <<'SQL'
DROP DATABASE IF EXISTS `fnt`;
CREATE DATABASE IF NOT EXISTS `fnt` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
DROP DATABASE IF EXISTS `fnt_log`;
CREATE DATABASE IF NOT EXISTS `fnt_log` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
SQL

# =======================
# Импорт SQL
#  Примечание: entrypoint контейнера уже мог попытаться выполнить твои .sql файлы.
#  Здесь мы импортируем гарантированно в нужные БД (через "mysql … fnt < file.sql"),
#  чтобы не зависеть от содержания дампа (USE/…).
# =======================
docker exec -i "$DB_CONTAINER" sh -s <<'SH'
set -e
# Базовые права/пользователи и т.п.
if [ -f /docker-entrypoint-initdb.d/01init.sql ]; then
  mysql -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" < /docker-entrypoint-initdb.d/01init.sql
fi

# Дамп схемы fnt (если есть)
if [ -f /docker-entrypoint-initdb.d/2024-01-01T12:56:53.fnt.sql ]; then
  mysql -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" fnt < /docker-entrypoint-initdb.d/2024-01-01T12:56:53.fnt.sql
fi

# Дополнительные скрипты (идём по факту наличия)
[ -f /docker-entrypoint-initdb.d/init_paper_print.sql ]       && mysql -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" fnt     < /docker-entrypoint-initdb.d/init_paper_print.sql
[ -f /docker-entrypoint-initdb.d/init_business_day.sql ]      && mysql -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" fnt     < /docker-entrypoint-initdb.d/init_business_day.sql
[ -f /docker-entrypoint-initdb.d/init_bug_report.sql ]        && mysql -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" fnt     < /docker-entrypoint-initdb.d/init_bug_report.sql
[ -f /docker-entrypoint-initdb.d/init_fnt_log.sql ]           && mysql -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" fnt_log < /docker-entrypoint-initdb.d/init_fnt_log.sql
[ -f /docker-entrypoint-initdb.d/patch]()
