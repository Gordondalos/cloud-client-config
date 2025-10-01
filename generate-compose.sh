#!/bin/bash

set -e

# Загружаем переменные из .env
set -a
source .env
set +a

# Проверка переменной
if [[ -z "$BD_PROXY_ID" ]]; then
  echo "[ERROR] BD_PROXY_ID is not set in .env"
  exit 1
fi


echo "✅ docker-compose.yml сгенерирован успешно"

# Генерация временного шаблона, где ключи тоже подставляются
TMP_FILE=$(mktemp)
sed "s/db-\${BD_PROXY_ID}/db-${BD_PROXY_ID}/g; s/bd-proxy-\${BD_PROXY_ID}/bd-proxy-${BD_PROXY_ID}/g" docker-compose.template.yml > "$TMP_FILE"

# Теперь подставляем оставшиеся переменные окружения
envsubst < "$TMP_FILE" > docker-compose.yml

# Удаляем временный файл
rm "$TMP_FILE"

