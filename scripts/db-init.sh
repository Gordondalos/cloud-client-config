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
# Ожидание готовности MySQL (устойчиво к временному серверу)
# =======================
echo "Ожидание готовности $DB_CONTAINER (MySQL)..."

# 0) Если есть healthcheck — подождём до healthy (до 5 минут)
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
      echo "Healthcheck не стал healthy за 5 минут — продолжаем ожидание через логи и ping."
      break
    fi
  done
fi

# 1) Дождаться конца ВРЕМЕННОГО сервера (порт 0) по маркеру entrypoint'а
#    "MySQL init process done. Ready for start up."
MAX_INIT_WAIT=420 # ~7 минут на медленных дисках
INIT_DONE=0
while [ $MAX_INIT_WAIT -gt 0 ]; do
  if docker logs "$DB_CONTAINER" 2>&1 | grep -q "MySQL init process done. Ready for start up."; then
    INIT_DONE=1
    break
  fi
  sleep 2
  MAX_INIT_WAIT=$((MAX_INIT_WAIT-2))
done

if [ "$INIT_DONE" -ne 1 ]; then
  echo "Не дождались завершения init-процесса MySQL. Хвост логов:"
  docker logs "$DB_CONTAINER" | tail -n 200
  exit 1
fi

# 2) Дождаться, что сервер принял root-пароль (ping с паролем)
PING_OK=0
for i in $(seq 1 150); do  # ~5 минут
  if docker exec "$DB_CONTAINER" sh -lc 'mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' 2>/dev/null; then
    PING_OK=1
    break
  fi
  sleep 2
done

# 2a) Если с паролем не пингуется, но БЕЗ пароля пингуется — зададим пароль сами.
if [ "$PING_OK" -ne 1 ]; then
  if docker exec "$DB_CONTAINER" sh -lc 'mysqladmin ping -uroot --silent' 2>/dev/null; then
    echo "root пока без пароля — задаём MYSQL_ROOT_PASSWORD внутри контейнера…"
    # Пытаемся выставить пароль root локально и для % (на всякий случай)
    docker exec -i "$DB_CONTAINER_
