#!/usr/bin/env bash
# Вывод списка всех клиентов в VLESS-inbound.
# Использование: ./list-users.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
trap cleanup_cookies EXIT

load_env
xui_login

INBOUND_JSON=$(xui_get "/panel/api/inbounds/get/${INBOUND_ID}")
CLIENTS=$(echo "${INBOUND_JSON}" | jq -r '.obj.settings | fromjson | .clients')

if [ "$(echo "${CLIENTS}" | jq 'length')" -eq 0 ]; then
    echo "Нет активных пользователей."
    exit 0
fi

echo ""
printf "%-25s %-40s %s\n" "ИМЯ" "UUID" "СОСТОЯНИЕ"
printf "%-25s %-40s %s\n" "-------------------------" "----------------------------------------" "----------"

echo "${CLIENTS}" | jq -r '.[] | "\(.email)\t\(.id)\t\(if .enable then "active" else "disabled" end)"' \
    | while IFS=$'\t' read -r email uuid state; do
        printf "%-25s %-40s %s\n" "${email}" "${uuid}" "${state}"
    done

echo ""
echo "Чтобы получить ссылку для пользователя: см. setup.sh вывод или зайти в панель через SSH-туннель."
echo "Сгенерировать ссылку для конкретного пользователя:"
echo "${CLIENTS}" | jq -r '.[] | "  \(.email):  vless://\(.id)@<server>:'"${VLESS_PORT}"'?type=tcp&security=reality&pbk='"${REALITY_PUBLIC_KEY}"'&fp=chrome&sni='"${REALITY_SERVER_NAME}"'&sid='"${REALITY_SHORT_ID}"'&flow=xtls-rprx-vision#\(.email)"'
echo ""
