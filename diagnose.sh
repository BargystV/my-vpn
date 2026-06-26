#!/usr/bin/env bash
# Однокнопочная диагностика VPN-стенда (3x-ui + VLESS+Reality).
# Запускается на сервере; собирает всё, что нужно, чтобы понять состояние сервера
# при разборе нештатной ситуации.
#
# Использование на сервере:
#   /root/vpn/diagnose.sh
#   /root/vpn/diagnose.sh > /tmp/diag.txt   # затем скинуть файл в чат
#
# Удалённо без SSH-сессии:
#   ssh root@<VPS> 'bash -s' < diagnose.sh > diag.txt

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo /root/vpn)"
DB="${SCRIPT_DIR}/db/x-ui.db"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
CONTAINER="3xui"

section() { printf '\n=== %s ===\n' "$*"; }
exists()  { command -v "$1" >/dev/null 2>&1; }

section "TIME / UPTIME"
date -u +"%Y-%m-%d %H:%M:%S UTC"
uptime
echo "kernel: $(uname -srm)"

section "CONTAINER STATUS"
docker ps -a --filter "name=${CONTAINER}" --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}'
docker inspect "${CONTAINER}" --format \
  'started_at={{.State.StartedAt}} running={{.State.Running}} restarts={{.RestartCount}} oomkilled={{.State.OOMKilled}}' 2>/dev/null

section "RESOURCES"
df -h / | tail -1
free -h | head -2
echo "load: $(awk '{print $1, $2, $3}' /proc/loadavg)"

section "LISTEN PORTS (22/443/2053/8443)"
ss -ltnp 2>/dev/null | grep -E ':(22|443|2053|8443)\s' || ss -ltn

section "UFW"
ufw status numbered 2>/dev/null | head -20 || echo "(ufw недоступен)"

section "DB: INBOUNDS"
sqlite3 -header -column "${DB}" "SELECT id, enable, port, protocol, remark FROM inbounds;" 2>&1

section "DB: REALITY PARAMS"
sqlite3 "${DB}" "SELECT 'privateKey: ' || json_extract(stream_settings, '\$.realitySettings.privateKey') || char(10) || 'shortIds:   ' || json_extract(stream_settings, '\$.realitySettings.shortIds') || char(10) || 'dest:       ' || json_extract(stream_settings, '\$.realitySettings.dest') || char(10) || 'sni:        ' || json_extract(stream_settings, '\$.realitySettings.serverNames') FROM inbounds WHERE id=1;" 2>&1

section "DB: CLIENTS"
sqlite3 "${DB}" "SELECT json_extract(value,'\$.email') || '  ' || json_extract(value,'\$.id') || '  enable=' || json_extract(value,'\$.enable') FROM inbounds, json_each(json_extract(settings,'\$.clients')) WHERE inbounds.id=1;" 2>&1

section "RUNTIME CONFIG (/app/bin/config.json)"
docker exec "${CONTAINER}" cat /app/bin/config.json 2>/dev/null | python3 -c "
import sys, json
try:
    c = json.load(sys.stdin)
    log = c.get('log', {})
    print('log.access  =', repr(log.get('access')))
    print('log.error   =', repr(log.get('error')))
    print('log.loglevel=', repr(log.get('loglevel')))
    print('inbounds:')
    for ib in c.get('inbounds', []):
        print(f\"  {ib.get('listen','*')}:{ib.get('port')} {ib.get('protocol')}  tag={ib.get('tag')}\")
        rs = (ib.get('streamSettings') or {}).get('realitySettings')
        if rs: print(f\"    reality: dest={rs.get('dest')} shortIds={rs.get('shortIds')}\")
        s = ib.get('settings') or {}
        if 'clients' in s:
            print(f\"    clients: {[cl.get('email') for cl in s['clients']]}\")
except Exception as e:
    print('parse error:', e)
" 2>&1

section "DB ↔ RUNTIME CONSISTENCY"
db_pk=$(sqlite3 "${DB}" "SELECT json_extract(stream_settings,'\$.realitySettings.privateKey') FROM inbounds WHERE id=1;" 2>/dev/null)
rt_pk=$(docker exec "${CONTAINER}" cat /app/bin/config.json 2>/dev/null | python3 -c "
import sys, json
c = json.load(sys.stdin)
for ib in c.get('inbounds', []):
    if ib.get('protocol') == 'vless':
        rs = (ib.get('streamSettings') or {}).get('realitySettings') or {}
        print(rs.get('privateKey',''))
        break
" 2>/dev/null)
if [ -z "${rt_pk}" ]; then
    echo "FAIL: в runtime config нет VLESS-inbound. Скорее всего xray в zombie-state, нужен рестарт контейнера."
elif [ "${db_pk}" = "${rt_pk}" ]; then
    echo "OK: privateKey в БД совпадает с runtime"
else
    echo "MISMATCH: privateKey в БД ≠ runtime — рестарт контейнера регенерирует config"
fi

section "PROCESS UPTIME"
xray_pid=$(pgrep -f xray-linux-amd6 | head -1)
[ -n "${xray_pid}" ] && echo "xray host PID=${xray_pid} uptime=$(ps -o etime= -p ${xray_pid} | tr -d ' ')"
xui_pid=$(pgrep -fx '/app/x-ui' | head -1)
[ -n "${xui_pid}" ] && echo "x-ui host PID=${xui_pid} uptime=$(ps -o etime= -p ${xui_pid} | tr -d ' ')"

section "REALITY FALLBACK PROBE (внутри хоста)"
probe=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:8443 \
        -servername www.bing.com 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null)
if echo "${probe}" | grep -q 'CN.*bing\.com'; then
    echo "OK: VPS:8443 проксирует TLS на bing.com (Reality жив)"
else
    echo "FAIL: Reality fallback не работает. xray, скорее всего, deadlocked — рестарт контейнера."
fi

section "RECENT 3xui.log (last 30)"
docker exec "${CONTAINER}" tail -30 /var/log/x-ui/3xui.log 2>&1

section "RECENT xray-error.log (last 30)"
docker exec "${CONTAINER}" tail -30 /var/log/xray-error.log 2>/dev/null || echo "(error log пуст или access log ещё не включён)"

section "RECENT xray-access.log (last 50)"
docker exec "${CONTAINER}" tail -50 /var/log/xray-access.log 2>/dev/null || echo "(access log пуст или ещё не включён — см. setup.sh шаг enable_access_log)"

section "GRPC/Xray health (from x-ui logs, last 24h)"
docker logs --since 24h "${CONTAINER}" 2>&1 | grep -iE 'rpc error|StatusServiceClient|xray.*started|xray.*stopped|panic|fatal|deadlineexceeded' | tail -20

section "DONE"
date -u +"%Y-%m-%d %H:%M:%S UTC"
