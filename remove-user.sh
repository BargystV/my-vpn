#!/usr/bin/env bash
# Удалить клиента по имени из VLESS-inbound.
# Использование: ./remove-user.sh <имя>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
trap cleanup_cookies EXIT

if [ "$#" -ne 1 ]; then
    echo "Использование: $0 <имя_пользователя>" >&2
    exit 1
fi

CLIENT_NAME="$1"

load_env
xui_login

# Найти UUID клиента по email
INBOUND_JSON=$(xui_get "/panel/api/inbounds/get/${INBOUND_ID}")
CLIENT_UUID=$(echo "${INBOUND_JSON}" | jq -r --arg name "${CLIENT_NAME}" '.obj.settings | fromjson | .clients[] | select(.email == $name) | .id' 2>/dev/null || true)

if [ -z "${CLIENT_UUID}" ]; then
    echo "Error: пользователь '${CLIENT_NAME}' не найден." >&2
    exit 1
fi

# POST /panel/api/inbounds/<id>/delClient/<uuid>
RESULT=$(xui_post "/panel/api/inbounds/${INBOUND_ID}/delClient/${CLIENT_UUID}")

if ! echo "${RESULT}" | jq -e '.success == true' >/dev/null; then
    echo "Error: не удалось удалить клиента: ${RESULT}" >&2
    exit 1
fi

echo "Пользователь '${CLIENT_NAME}' (UUID: ${CLIENT_UUID}) удалён."
