#!/usr/bin/env bash
# Общие функции для setup.sh и helper-скриптов.
# Всегда source-ить, не запускать напрямую.

set -euo pipefail

# Определяем корень проекта относительно расположения этого файла
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
COOKIE_JAR="${PROJECT_ROOT}/.cookies.${$}.txt"

# Загрузить .env (если существует)
load_env() {
    if [ ! -f "${ENV_FILE}" ]; then
        echo "Error: ${ENV_FILE} not found. Запустите setup.sh сначала." >&2
        exit 1
    fi
    set -o allexport
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +o allexport
}

# Базовый URL панели на loopback
panel_base_url() {
    echo "http://127.0.0.1:${XUI_PANEL_PORT}${XUI_WEB_BASE_PATH%/}"
}

# Логин в панель, сохраняет cookie в COOKIE_JAR.
# Аргументы: $1=username $2=password $3=base_path (с ведущим/завершающим слешем, например /admin/)
xui_login_raw() {
    local username="$1" password="$2" base_path="$3"
    local url="http://127.0.0.1:${XUI_PANEL_PORT}${base_path%/}/login"
    rm -f "${COOKIE_JAR}"
    local response
    response=$(curl -fsS -c "${COOKIE_JAR}" -X POST "${url}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${username}&password=${password}")
    if ! echo "${response}" | jq -e '.success == true' >/dev/null; then
        echo "Login failed at ${url}: ${response}" >&2
        return 1
    fi
}

# Логин с текущими значениями из .env
xui_login() {
    xui_login_raw "${XUI_USERNAME}" "${XUI_PASSWORD}" "${XUI_WEB_BASE_PATH}"
}

# GET запрос к API панели. Аргумент: $1=relative_path (например, /panel/api/inbounds/list).
# Учитывает webBasePath: финальный URL = base_url + relative_path с убиранием webBasePath из relative_path,
# потому что в 3X-UI все API endpoint'ы маунтятся под webBasePath.
# Использование: xui_get /panel/api/inbounds/list
xui_get() {
    local rel="$1"
    local base_url
    base_url="$(panel_base_url)"
    curl -fsS -b "${COOKIE_JAR}" "${base_url}${rel}"
}

# POST запрос к API. $1=relative_path, $2=form data string (опционально)
xui_post() {
    local rel="$1"
    local data="${2:-}"
    local base_url
    base_url="$(panel_base_url)"
    if [ -z "${data}" ]; then
        curl -fsS -b "${COOKIE_JAR}" -X POST "${base_url}${rel}"
    else
        curl -fsS -b "${COOKIE_JAR}" -X POST "${base_url}${rel}" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "${data}"
    fi
}

# Получить публичный IP сервера (с фолбэком)
get_server_ip() {
    curl -fsSL https://ifconfig.me 2>/dev/null \
        || curl -fsSL https://api.ipify.org 2>/dev/null \
        || echo "<your-server-ip>"
}

# Сформировать vless:// ссылку для клиента.
# Аргументы: $1=client_uuid $2=client_remark
build_vless_link() {
    local uuid="$1" remark="$2"
    local server_ip
    server_ip="$(get_server_ip)"
    # Параметры Reality согласно спецификации xray-core
    printf 'vless://%s@%s:%s?type=tcp&security=reality&pbk=%s&fp=chrome&sni=%s&sid=%s&flow=xtls-rprx-vision#%s\n' \
        "${uuid}" \
        "${server_ip}" \
        "${VLESS_PORT}" \
        "${REALITY_PUBLIC_KEY}" \
        "${REALITY_SERVER_NAME}" \
        "${REALITY_SHORT_ID}" \
        "${remark}"
}

# Вывод QR-кода в терминал
print_qr() {
    local link="$1"
    if command -v qrencode >/dev/null 2>&1; then
        echo "${link}" | qrencode -t ANSIUTF8
    else
        echo "(qrencode не установлен — пропускаю QR; используйте ссылку выше)"
    fi
}

# Cleanup cookie-файла. Caller-скрипты должны явно регистрировать trap:
#   trap cleanup_cookies EXIT
cleanup_cookies() {
    rm -f "${COOKIE_JAR}"
}
