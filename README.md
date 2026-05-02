# VLESS+Reality VPN on 3X-UI

Self-hosted VLESS+Reality VPN на базе [3X-UI](https://github.com/mhsanaei/3x-ui) и [Xray-core](https://github.com/XTLS/Xray-core). Один скрипт разворачивает всё на чистом Ubuntu VPS.

Рассчитан на личное использование и небольшие группы (семья, близкие — до ~10 человек). Веб-панель 3X-UI закрыта наружу, доступ только через SSH-туннель. Маскировка трафика под реальный HTTPS — устойчивость к DPI.

## Что делает

- Поднимает 3X-UI (Xray-core) в Docker на порту 8443/tcp с VLESS+Reality (XTLS-Vision)
- Маскирует трафик под HTTPS к `www.microsoft.com` (меняется в `.env`)
- Настраивает UFW (открывает только 22 и 8443; существующие правила не трогает)
- Держит веб-панель 3X-UI закрытой — доступ только через SSH-туннель
- Генерирует первого пользователя и выдаёт `vless://` ссылку + QR-код

## Требования

- Ubuntu VPS (1 vCPU, 512 MB RAM достаточно)
- Root-доступ по SSH
- Docker / Docker Compose — если не установлены, `setup.sh` поставит автоматически

## Установка

**На VPS:**

```bash
ssh root@<VPS_IP>
git clone https://github.com/<your-username>/<repo>.git ~/vpn
cd ~/vpn
sudo bash setup.sh
```

`setup.sh` идемпотентен — можно запускать повторно, существующая конфигурация не перезаписывается.

В выводе появятся: `vless://`-ссылка для подключения, QR-код, креды панели и команда SSH-туннеля.

## Управление пользователями

```bash
./add-user.sh mama       # добавить нового клиента
./list-users.sh          # показать всех
./remove-user.sh mama    # удалить клиента
```

`add-user.sh` выводит `vless://` ссылку и ASCII QR-код — можно переслать человеку в мессенджере или показать с экрана.

## Клиенты

Любой клиент с поддержкой VLESS + Reality + XTLS-Vision:

| Платформа | Рекомендуемое приложение |
|---|---|
| iOS | [Hiddify](https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532) · [V2Box](https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690) · [FoXray](https://apps.apple.com/us/app/foxray/id6448898396) |
| Android | [Hiddify](https://play.google.com/store/apps/details?id=app.hiddify.com) · [v2rayNG](https://play.google.com/store/apps/details?id=com.v2ray.ang) |
| Windows / Linux | [Hiddify Desktop](https://github.com/hiddify/hiddify-app/releases) · [Nekoray](https://github.com/MatsuriDayo/nekoray/releases) |
| macOS | [V2Box](https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690) (рекомендую: подписан Apple, работает из коробки) |

В любом клиенте: `+` → **Сканировать QR** или **Import from clipboard** → подключиться.

## Веб-панель (для ручного управления)

Панель закрыта снаружи. Доступ — только через SSH-туннель:

```bash
# С локальной машины:
ssh -L 2053:localhost:2053 root@<VPS_IP>
# Затем в браузере: http://localhost:2053/<путь_из_.env>/
# Логин/пароль из .env на сервере
```

Helper-скрипты (`add/list/remove-user.sh`) покрывают 90% задач без панели.

## Обновление

```bash
ssh root@<VPS_IP>
cd ~/vpn
git pull
docker compose pull && docker compose up -d
```

При обновлении образа клиенты переподключаются автоматически (downtime ~5 секунд).

## Бэкап

Состояние панели и пользователей — в `./db/x-ui.db` (SQLite).

```bash
# На VPS
tar czf vpn-backup-$(date +%F).tar.gz .env db/

# С локальной машины — забрать копию
scp root@<VPS_IP>:~/vpn/vpn-backup-*.tar.gz ~/Downloads/
```

Восстановление: распаковать архив в папку проекта на новом VPS → `docker compose up -d`. Клиенты продолжат работать по старым ссылкам.

## Безопасность

- **Reality** — трафик неотличим от обычного HTTPS к реальному сайту (по умолчанию `www.microsoft.com`)
- **Веб-панель закрыта в UFW** — снаружи порт `2053` недоступен
- **Кастомный путь панели** (`/<32 hex>/`) — защита от случайного сканирования даже при открытом порте
- **Пароль панели** — 32 случайных символа, в `.env` с `chmod 600`
- **fail2ban** активен в контейнере 3X-UI (встроенная защита от brute-force)
- **Секреты** (`.env`, `db/`, cookies) — в `.gitignore`, в репозиторий не попадают
- **Reality private key** никогда не покидает сервер, клиенту выдаётся только public key

## Если что-то не работает

Однокнопочная диагностика — собирает на сервере всё, что нужно для разбора:

```bash
ssh root@<VPS_IP> '/root/vpn/diagnose.sh' > diag.txt
```

`diagnose.sh` выводит: статус контейнера, использование диска/памяти, listening-порты, UFW, текущие inbounds и клиентов из БД, проверку соответствия БД ↔ runtime config, Reality fallback probe (`openssl s_client` к localhost:8443), последние записи xray access/error log и `3xui.log`. По этому файлу видна полная картина здоровья стенда.

Сетап включает access log xray (`/var/log/xray-access.log` внутри контейнера) — там видны все клиентские подключения с IP, email и направлением. По умолчанию в 3X-UI access log выключен, наш `setup.sh` явно его включает (шаг `[9/9]`).

Ручные проверки, если diagnose.sh почему-то недоступен:

```bash
docker compose logs -f 3xui          # логи панели и xray-core
docker compose ps                    # контейнер живой?
ss -tlnp | grep -E '8443|2053'       # порты слушаются?
ufw status numbered                  # правила файрвола
curl -sI https://www.microsoft.com   # маскировочный домен доступен с VPS?
./list-users.sh                      # активные клиенты
```

### Частые проблемы на стороне клиента

- **Некоторые сайты (Instagram, TikTok) не открываются через VPN у провайдера в РФ** — провайдер блокирует домены на уровне DNS. Фикс: прописать в системе DNS `1.1.1.1` или `8.8.8.8` вместо DNS роутера.
- **На macOS Hiddify Desktop иногда валит `failed to start background core`** — использовать [V2Box](https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690) вместо него (подписан Apple, без helper-процессов).
- **Telegram не работает при включённом клиенте в режиме "System Proxy"** — переключить на режим **TUN** / **VPN** (System Proxy заворачивает только HTTP/HTTPS, но не MTProto).

## Структура проекта

| Файл | Назначение |
|---|---|
| `setup.sh` | Идемпотентный bash-скрипт первичной установки |
| `docker-compose.yml` | Один сервис `3xui` (network_mode: host) |
| `add-user.sh`, `list-users.sh`, `remove-user.sh` | Helper-скрипты для пользователей |
| `diagnose.sh` | Однокнопочная диагностика стенда при сбоях |
| `lib/common.sh` | Общие функции (login, API-вызовы, QR) |
| `.env.example` | Шаблон (реальный `.env` генерируется `setup.sh`) |
| `CLAUDE.md` | Контекст проекта для [Claude Code](https://claude.com/claude-code) |

## Лицензия

[MIT](LICENSE)
