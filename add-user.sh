#!/usr/bin/env bash
# Добавить нового клиента в существующий VLESS-inbound.
# Использование: ./add-user.sh <имя>

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

# Получаем UUID через API (3X-UI может вернуть obj как строку или {uuid: "..."})
UUID_JSON=$(xui_get "/panel/api/server/getNewUUID")
NEW_UUID=$(echo "${UUID_JSON}" | jq -r 'if (.obj | type) == "object" then .obj.uuid else .obj end')
[ -n "${NEW_UUID}" ] && [ "${NEW_UUID}" != "null" ] || { echo "Error: пустой UUID от API"; exit 1; }

# Проверка: клиент с таким email уже существует?
INBOUND_JSON=$(xui_get "/panel/api/inbounds/get/${INBOUND_ID}")
EXISTING=$(echo "${INBOUND_JSON}" | jq -r --arg name "${CLIENT_NAME}" '.obj.settings | fromjson | .clients[] | select(.email == $name) | .id' 2>/dev/null || true)
if [ -n "${EXISTING}" ]; then
    echo "Error: пользователь '${CLIENT_NAME}' уже существует (UUID: ${EXISTING})." >&2
    exit 1
fi

# Формируем JSON клиента
CLIENT_JSON=$(jq -nc \
    --arg uuid "${NEW_UUID}" \
    --arg email "${CLIENT_NAME}" \
    '{
        clients: [{
            id: $uuid,
            flow: "xtls-rprx-vision",
            email: $email,
            limitIp: 0,
            totalGB: 0,
            expiryTime: 0,
            enable: true,
            tgId: "",
            subId: "",
            reset: 0
        }]
    }')

# POST addClient
RESULT=$(xui_post "/panel/api/inbounds/addClient" \
    "id=${INBOUND_ID}&settings=$(printf %s "${CLIENT_JSON}" | jq -sRr @uri)")

if ! echo "${RESULT}" | jq -e '.success == true' >/dev/null; then
    echo "Error: не удалось добавить клиента: ${RESULT}" >&2
    exit 1
fi

# Вывод
LINK=$(build_vless_link "${NEW_UUID}" "${CLIENT_NAME}")
echo ""
echo "Пользователь '${CLIENT_NAME}' добавлен (UUID: ${NEW_UUID})."
echo ""
echo "Ссылка для подключения:"
echo "  ${LINK}"
echo ""
echo "QR-код:"
print_qr "${LINK}"
echo ""
