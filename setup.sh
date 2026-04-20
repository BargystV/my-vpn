#!/usr/bin/env bash
# 3X-UI VPN (VLESS+Reality) — первичная установка на чистый Ubuntu VPS.
# Идемпотентен: повторный запуск не ломает существующую установку.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
trap cleanup_cookies EXIT

echo "=== 3X-UI VPN Setup ==="
echo ""

# 1. Проверка root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: запустите как root (sudo bash setup.sh)" >&2
    exit 1
fi

# 2. Проверка/установка Docker
echo "[1/8] Проверка Docker..."
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker не найден — устанавливаю..."
    curl -fsSL https://get.docker.com | sh
else
    echo "Docker уже установлен — пропускаю."
fi

# 3. Установка вспомогательных пакетов
echo "[2/8] Установка зависимостей (jq, qrencode, curl, ufw)..."
apt-get update -qq
apt-get install -y -qq jq qrencode curl ufw

# 4. Генерация локальных секретов и .env (только если .env не существует)
echo "[3/8] Генерация секретов..."
if [ -f "${SCRIPT_DIR}/.env" ]; then
    echo ".env уже существует — НЕ перезаписываю (идемпотентность)."
else
    # Subshell отключает pipefail для этого pipeline: head -c 32 закрывает pipe раньше,
    # tr получает SIGPIPE (exit 141) — без pipefail это нормально.
    XUI_PASSWORD_GEN=$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    XUI_WEB_BASE_PATH_GEN="/$(set +o pipefail; head -c 16 /dev/urandom | xxd -p | tr -d '\n')/"
    REALITY_SHORT_ID_GEN=$(set +o pipefail; head -c 4 /dev/urandom | xxd -p | tr -d '\n')

    install -m 600 /dev/null "${SCRIPT_DIR}/.env"
    cat > "${SCRIPT_DIR}/.env" <<EOF
# Сгенерировано setup.sh $(date -u +%Y-%m-%dT%H:%M:%SZ). НЕ редактировать руками.

# Панель 3X-UI
XUI_USERNAME=admin
XUI_PASSWORD=${XUI_PASSWORD_GEN}
XUI_WEB_BASE_PATH=${XUI_WEB_BASE_PATH_GEN}
XUI_PANEL_PORT=2053

# VLESS+Reality
VLESS_PORT=8443
REALITY_DEST=www.microsoft.com:443
REALITY_SERVER_NAME=www.microsoft.com
REALITY_PRIVATE_KEY=
REALITY_PUBLIC_KEY=
REALITY_SHORT_ID=${REALITY_SHORT_ID_GEN}

# Первый клиент
FIRST_CLIENT_NAME=admin
FIRST_CLIENT_UUID=

# ID inbound'а в БД 3X-UI
INBOUND_ID=
EOF
    chmod 600 "${SCRIPT_DIR}/.env"
    echo ".env создан (chmod 600)."
fi

# Загрузить переменные из .env
load_env

# 5. Запуск контейнера 3X-UI
echo "[4/8] Запуск контейнера 3X-UI..."
mkdir -p "${SCRIPT_DIR}/db" "${SCRIPT_DIR}/cert"
docker compose up -d

# 6. UFW: allow 8443/tcp (порт VLESS), панель 2053 не открывать
echo "[5/8] Настройка файрвола..."
# Базовые правила (если UFW ещё не настроен)
ufw default deny incoming || true
ufw default allow outgoing || true
ufw allow 22/tcp comment 'SSH' || true
# Не трогаем 443/tcp — там уже MTProxy
ufw allow 8443/tcp comment 'VLESS Reality' || true
echo "y" | ufw enable >/dev/null 2>&1 || true
ufw status numbered

# 7. Ждём готовности панели (проверяем оба пути: дефолтный / и кастомный из .env)
echo "[6/8] Ожидание готовности панели..."
PANEL_BASE_PATH_NORMALIZED="${XUI_WEB_BASE_PATH%/}/"
for i in {1..60}; do
    if curl -fsS "http://127.0.0.1:${XUI_PANEL_PORT}/" >/dev/null 2>&1 \
        || curl -fsS "http://127.0.0.1:${XUI_PANEL_PORT}${PANEL_BASE_PATH_NORMALIZED}" >/dev/null 2>&1; then
        echo "Панель отвечает."
        break
    fi
    sleep 1
    if [ "${i}" -eq 60 ]; then
        echo "Error: панель не отвечает за 60 секунд. См. 'docker compose logs 3xui'." >&2
        exit 1
    fi
done

# 8. Конфигурация панели через CLI x-ui (надёжнее HTTP API: пишет напрямую в SQLite, идемпотентен)
echo "[7/8] Настройка панели..."

# Проверяем текущие настройки панели — если совпадают с .env, пропускаем reconfig + restart
CURRENT_SETTINGS=$(docker exec 3xui /app/x-ui setting -show 2>/dev/null || true)
CURRENT_BASE_PATH=$(echo "${CURRENT_SETTINGS}" | awk -F': ' '/^webBasePath:/ {print $2}')

if [ "${CURRENT_BASE_PATH}" = "${XUI_WEB_BASE_PATH}" ] \
    && xui_login_raw "${XUI_USERNAME}" "${XUI_PASSWORD}" "${XUI_WEB_BASE_PATH}" 2>/dev/null; then
    echo "Панель уже настроена с актуальными кредами и путём — пропускаю."
else
    # Применяем настройки через x-ui CLI (бинарь внутри контейнера, прямая запись в БД)
    docker exec 3xui /app/x-ui setting \
        -username "${XUI_USERNAME}" \
        -password "${XUI_PASSWORD}" \
        -webBasePath "${XUI_WEB_BASE_PATH}" \
        -port "${XUI_PANEL_PORT}"

    # Перезапуск контейнера для применения webBasePath/port
    echo "Перезапуск контейнера для применения настроек..."
    docker compose restart 3xui >/dev/null

    # Ждём готовности новой панели и проверяем что login работает
    echo "Ожидание перезапуска панели..."
    sleep 5
    for i in {1..30}; do
        if xui_login 2>/dev/null; then
            echo "Панель готова с новыми кредами."
            break
        fi
        sleep 1
        if [ "${i}" -eq 30 ]; then
            echo "Error: не удалось залогиниться новыми кредами после рестарта." >&2
            exit 1
        fi
    done
fi

# Финальный логин для последующих API-вызовов (cookie сохраняется)
xui_login

# 9. Если REALITY_PRIVATE_KEY ещё пустой — получаем через API
if [ -z "${REALITY_PRIVATE_KEY}" ]; then
    echo "Генерация Reality keypair..."
    KEYS_JSON=$(xui_get "/panel/api/server/getNewX25519Cert")
    NEW_PRIVATE=$(echo "${KEYS_JSON}" | jq -r '.obj.privateKey')
    NEW_PUBLIC=$(echo "${KEYS_JSON}" | jq -r '.obj.publicKey')
    [ -n "${NEW_PRIVATE}" ] && [ "${NEW_PRIVATE}" != "null" ] || { echo "Error: пустой privateKey от API"; exit 1; }
    sed -i "s|^REALITY_PRIVATE_KEY=.*|REALITY_PRIVATE_KEY=${NEW_PRIVATE}|" "${SCRIPT_DIR}/.env"
    sed -i "s|^REALITY_PUBLIC_KEY=.*|REALITY_PUBLIC_KEY=${NEW_PUBLIC}|" "${SCRIPT_DIR}/.env"
    REALITY_PRIVATE_KEY="${NEW_PRIVATE}"
    REALITY_PUBLIC_KEY="${NEW_PUBLIC}"
fi

# 10. Если FIRST_CLIENT_UUID ещё пустой — получаем через API
# 3X-UI может вернуть obj как строку или как {uuid: "..."} — поддерживаем оба формата
if [ -z "${FIRST_CLIENT_UUID}" ]; then
    echo "Генерация UUID первого клиента..."
    UUID_JSON=$(xui_get "/panel/api/server/getNewUUID")
    NEW_UUID=$(echo "${UUID_JSON}" | jq -r 'if (.obj | type) == "object" then .obj.uuid else .obj end')
    [ -n "${NEW_UUID}" ] && [ "${NEW_UUID}" != "null" ] || { echo "Error: пустой UUID от API"; exit 1; }
    sed -i "s|^FIRST_CLIENT_UUID=.*|FIRST_CLIENT_UUID=${NEW_UUID}|" "${SCRIPT_DIR}/.env"
    FIRST_CLIENT_UUID="${NEW_UUID}"
fi

# 11. Если INBOUND_ID ещё пустой — создаём первый inbound
if [ -z "${INBOUND_ID}" ]; then
    echo "[8/8] Создание первого inbound (VLESS+Reality)..."

    # Подготовка JSON для settings и streamSettings
    SETTINGS_JSON=$(jq -nc \
        --arg uuid "${FIRST_CLIENT_UUID}" \
        --arg email "${FIRST_CLIENT_NAME}" \
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
            }],
            decryption: "none",
            fallbacks: []
        }')

    STREAM_JSON=$(jq -nc \
        --arg dest "${REALITY_DEST}" \
        --arg sni "${REALITY_SERVER_NAME}" \
        --arg priv "${REALITY_PRIVATE_KEY}" \
        --arg sid "${REALITY_SHORT_ID}" \
        '{
            network: "tcp",
            security: "reality",
            realitySettings: {
                show: false,
                xver: 0,
                dest: $dest,
                serverNames: [$sni],
                privateKey: $priv,
                minClient: "",
                maxClient: "",
                maxTimediff: 0,
                shortIds: [$sid],
                settings: {
                    publicKey: "",
                    fingerprint: "chrome",
                    serverName: "",
                    spiderX: "/"
                }
            },
            tcpSettings: {
                acceptProxyProtocol: false,
                header: { type: "none" }
            }
        }')

    SNIFFING_JSON='{"enabled":true,"destOverride":["http","tls","quic"]}'

    # POST /panel/api/inbounds/add
    ADD_RESULT=$(xui_post "/panel/api/inbounds/add" \
        "remark=VLESS-Reality-Family&enable=true&listen=&port=${VLESS_PORT}&protocol=vless&expiryTime=0&total=0&settings=$(printf %s "${SETTINGS_JSON}" | jq -sRr @uri)&streamSettings=$(printf %s "${STREAM_JSON}" | jq -sRr @uri)&sniffing=$(printf %s "${SNIFFING_JSON}" | jq -sRr @uri)")

    if ! echo "${ADD_RESULT}" | jq -e '.success == true' >/dev/null; then
        echo "Error: не удалось создать inbound: ${ADD_RESULT}" >&2
        exit 1
    fi

    NEW_INBOUND_ID=$(echo "${ADD_RESULT}" | jq -r '.obj.id')
    sed -i "s|^INBOUND_ID=.*|INBOUND_ID=${NEW_INBOUND_ID}|" "${SCRIPT_DIR}/.env"
    INBOUND_ID="${NEW_INBOUND_ID}"
    echo "Inbound создан, ID=${INBOUND_ID}."
else
    echo "Inbound уже существует (ID=${INBOUND_ID}) — пропускаю."
fi

# 12. Финальный вывод
SERVER_IP=$(get_server_ip)
VLESS_LINK=$(build_vless_link "${FIRST_CLIENT_UUID}" "${FIRST_CLIENT_NAME}")

echo ""
echo "================================================"
echo "  3X-UI VPN готов!"
echo "================================================"
echo ""
echo "Ссылка для подключения первого клиента (${FIRST_CLIENT_NAME}):"
echo "  ${VLESS_LINK}"
echo ""
echo "QR-код:"
print_qr "${VLESS_LINK}"
echo ""
echo "Веб-панель 3X-UI (доступ ТОЛЬКО через SSH-туннель):"
echo "  С локальной машины:  ssh -L ${XUI_PANEL_PORT}:localhost:${XUI_PANEL_PORT} root@${SERVER_IP}"
echo "  Затем в браузере:    http://localhost:${XUI_PANEL_PORT}${XUI_WEB_BASE_PATH}"
echo "  Логин:               ${XUI_USERNAME}"
echo "  Пароль:              ${XUI_PASSWORD}"
echo ""
echo "Управление пользователями:"
echo "  ./add-user.sh <имя>"
echo "  ./list-users.sh"
echo "  ./remove-user.sh <имя>"
echo ""
echo "MTProxy на 443/tcp не затронут и продолжает работать."
echo ""
