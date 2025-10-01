#!/bin/bash
set -e

# Determine script directory and set log file path
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOGFILE="$SCRIPT_DIR/Update.log"

: > "$LOGFILE"
exec >"$LOGFILE" 2>&1

# Pull latest repository changes before proceeding
echo "📦 Pulling latest git changes..."
git pull || echo "⚠️ git pull failed, continuing"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║                        кредитпро                         ║"
echo "╚══════════════════════════════════════════════════════════╝"

echo "============================================================"
echo " Update started at $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo

# Загрузим переменные окружения
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ .env not found"
  exit 1
fi

CONTAINER_NAME="bd-proxy-${BD_PROXY_ID}"

echo "🔄 Pulling latest docker images..."
docker compose pull || echo "⚠️ docker-compose.yml not found, skipping docker compose pull"

echo "🚀 Starting services..."
npm run start

echo "⏳ Waiting for container $CONTAINER_NAME to be ready..."

# Ожидаем, пока контейнер станет "running"
MAX_RETRIES=30
RETRY_INTERVAL=2
i=0

until docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" | grep -q "$CONTAINER_NAME"; do
  if [ $i -ge $MAX_RETRIES ]; then
    echo "❌ Контейнер $CONTAINER_NAME не запустился вовремя"
    exit 1
  fi
  echo "⏱️  $((MAX_RETRIES - i)) сек осталось..."
  sleep $RETRY_INTERVAL
  ((i++))
done

echo "✅ $CONTAINER_NAME is running. Executing migrations..."

docker exec -i "$CONTAINER_NAME" /bin/sh -c "npm run migrate-run"

echo "🏁 Update complete on $(hostname)"
