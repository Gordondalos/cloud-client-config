#!/usr/bin/env bash
set -Eeuo pipefail

# Абсолютные пути
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${ROOT_DIR}/docker-compose.template.yml"
OUT="${ROOT_DIR}/docker-compose.yml"

if [[ ! -f "${TEMPLATE}" ]]; then
  echo "[ERROR] Не найден template: ${TEMPLATE}" >&2
  exit 1
fi

# Грузим .env из корня
if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  set +a
fi

# Обязательные
: "${BD_PROXY_ID:?BD_PROXY_ID is not set in .env}"
: "${IMAGE_TAG:?IMAGE_TAG is not set in .env}"

# Хостовый порт для MySQL — по умолчанию 33${ID} (22→3322, 25→3325 и т.п.)
export HOST_DB_PORT="${HOST_DB_PORT:-33${BD_PROXY_ID}}"

# Проектный префикс для изоляции ресурсов
export COMPOSE_PROJECT_NAME="client-${BD_PROXY_ID}"

# 1) в шаблоне есть «db-${BD_PROXY_ID}» и «bd-proxy-${BD_PROXY_ID}» в местах, где
# нужен именно вычисленный текст, а не envsubst; заменим их sed’ом
TMP_FILE="$(mktemp)"
sed \
  -e "s/db-\${BD_PROXY_ID}/db-${BD_PROXY_ID}/g" \
  -e "s/bd-proxy-\${BD_PROXY_ID}/bd-proxy-${BD_PROXY_ID}/g" \
  "${TEMPLATE}" > "${TMP_FILE}"

# 2) остальные ${VARS} подставим обычным envsubst (берёт из export’ов)
envsubst < "${TMP_FILE}" > "${OUT}"
rm -f "${TMP_FILE}"

echo "✅ docker-compose.yml сгенерирован: ${OUT}"
echo "   COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}"
echo "   DB container name   = db-${BD_PROXY_ID}"
echo "   APP container name  = bd-proxy-${BD_PROXY_ID}"
echo "   HOST_DB_PORT        = ${HOST_DB_PORT}"
