# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Self-hosted VLESS+Reality VPN deployment kit using the 3X-UI panel. Designed for small groups (family, close friends — up to ~10 users) on a budget Ubuntu VPS. Documentation (README) is in Russian, because the primary audience is Russian-speaking users bypassing DPI-based blocking. Goal: resist DPI fingerprinting of modern VPN protocols.

## Architecture

```
Client (Hiddify / v2rayNG / V2Box)
    │  TLS handshake mimics real HTTPS to www.bing.com
    ▼
VPS:8443/tcp (3X-UI / xray-core)
    │  VLESS + Reality + XTLS-Vision flow
    └─► Real TLS handshake to www.bing.com:443, then xray decrypts payload and proxies traffic

VPS:2053  ← closed in UFW, accessible only via SSH tunnel
    │  3X-UI web panel
    └─► ssh -L 2053:localhost:2053 root@<VPS_IP>  → http://localhost:2053/<XUI_WEB_BASE_PATH>/
```

- **Container image:** `ghcr.io/mhsanaei/3x-ui:latest`
- **Network mode:** `host` (required by 3X-UI for proper port handling with UFW)
- **Ports used:** 8443/tcp (VLESS+Reality), 2053/tcp (panel, bound to host, **not** exposed)

## Key Commands

```bash
# Deploy on a fresh Ubuntu VPS (or first-time setup)
sudo bash setup.sh

# Manage users
./add-user.sh <name>         # Create new client, output vless:// link + QR
./list-users.sh              # Show all clients
./remove-user.sh <name>      # Delete client by name

# Container management
docker compose up -d
docker compose down
docker compose logs -f 3xui
docker compose pull && docker compose up -d   # update image

# Open web panel from local machine (admin operations only)
ssh -L 2053:localhost:2053 root@<VPS_IP>
# Then in browser: http://localhost:2053/<XUI_WEB_BASE_PATH>/
# Credentials: see .env on the server
```

## Secret Format

All secrets are generated automatically by `setup.sh` and stored in `.env` (chmod 600, never committed):
- **Reality keypair (x25519):** generated via 3X-UI API endpoint `/panel/api/server/getNewX25519Cert`
- **Client UUIDs (v4):** generated via `/panel/api/server/getNewUUID`
- **Panel password:** 32-char alphanumeric, generated locally from `/dev/urandom`
- **Panel base path:** `/<32 hex chars>/`, generated locally from `/dev/urandom`
- **Reality shortId:** 8 hex chars, generated locally from `/dev/urandom`

## Ports & Firewall

`setup.sh` configures UFW to allow: 22 (SSH), 8443 (VLESS+Reality). Port 2053 (3X-UI web panel) is **not** opened externally — admin access is via SSH tunnel only. If another service already uses a port (e.g. 443), `setup.sh` does not touch existing UFW rules.

## Container Notes

- `network_mode: host` — required by 3X-UI for direct port binding and correct UFW interaction
- `XUI_ENABLE_FAIL2BAN: "true"` — protection against panel brute-force (in case panel ever gets exposed)
- `XRAY_VMESS_AEAD_FORCED: "false"` — backward compatibility with older clients
- Log rotation: 3 files × 10MB max
- State (panel DB, users, settings) persists in `./db/x-ui.db` — bind-mounted from host

## Helper Scripts Architecture

All scripts (`setup.sh`, `add-user.sh`, `list-users.sh`, `remove-user.sh`) source `lib/common.sh`, which provides:
- `load_env` — load `.env`
- `xui_login` / `xui_login_raw` — POST `/login`, save cookie
- `xui_get` / `xui_post` — wrappers around curl with cookie
- `build_vless_link` — assemble `vless://` URL from config
- `print_qr` — terminal QR-code via `qrencode -t ANSIUTF8`
- `cleanup_cookies` — remove cookie file (caller registers `trap cleanup_cookies EXIT`)

API endpoints used (all under `/<webBasePath>` after panel reconfiguration):
- `POST /login`
- `POST /panel/setting/updateUser` — change admin credentials
- `POST /panel/setting/update` — change webBasePath
- `POST /panel/setting/restartPanel`
- `GET  /panel/api/server/getNewX25519Cert`
- `GET  /panel/api/server/getNewUUID`
- `POST /panel/api/inbounds/add`
- `GET  /panel/api/inbounds/get/:id`
- `POST /panel/api/inbounds/addClient`
- `POST /panel/api/inbounds/:id/delClient/:uuid`

Note: some endpoints (e.g. `/panel/setting/update`) proved unreliable in 3X-UI 2.8.11 — `setup.sh` uses the in-container `/app/x-ui setting` CLI for panel reconfiguration instead (writes directly to SQLite).
