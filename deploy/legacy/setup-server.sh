#!/usr/bin/env bash
#
# NSky — автоматическая установка VPN-сервера.
#
# Ставит и настраивает за один запуск:
#   • Docker и firewall
#   • Remnawave Panel + Postgres + Valkey
#   • Caddy с HTTPS (Let's Encrypt)
#   • профиль Xray с тремя протоколами (VLESS+REALITY, XHTTP, Hysteria2)
#   • администратора панели с паролем
#   • API-токен
#   • ноду, привязанную к панели
#
# Использование:
#   bash setup-server.sh <домен> <email>
#
# Пример:
#   bash setup-server.sh oijas.rknmrz.xyz admin@example.com
#
# Требования: Ubuntu 22.04/24.04, root, домен уже указывает на IP сервера.
# Повторный запуск безопасен: данные и пароли не перезаписываются.

set -Eeuo pipefail

DOMAIN="${1:-}"
EMAIL="${2:-}"
DIR="/opt/nsky"
STATE="$DIR/install-state.env"
LOG="$DIR/install.log"

mkdir -p "$DIR"
exec > >(tee -a "$LOG") 2>&1

bold() { printf '\n\033[1;36m══ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash setup-server.sh домен email"
[[ -n "$DOMAIN" && -n "$EMAIL" ]] || die "Использование: bash setup-server.sh <домен> <email>"

rnd() { openssl rand -hex "$1"; }
# Пароль для панели: требование — 24+ символа, верхний/нижний регистр и цифры.
gen_password() { printf '%sAa9' "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"; }

api() { curl -fsS --max-time 30 "$@"; }

# ─────────────────────────────────────────────────────────────────────────────
bold "1/9. Проверка сервера"
# ─────────────────────────────────────────────────────────────────────────────
SERVER_IP="$(curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null || curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$SERVER_IP" ]] || die "Нет доступа в интернет с сервера"
ok "IP сервера: $SERVER_IP"

RESOLVED="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)"
if [[ "$RESOLVED" != "$SERVER_IP" ]]; then
  warn "Домен $DOMAIN указывает на '${RESOLVED:-ничего}', а IP сервера $SERVER_IP"
  warn "HTTPS не выпустится, пока DNS не совпадёт. Продолжаю."
else
  ok "Домен $DOMAIN указывает на этот сервер"
fi

ok "Память: $(awk '/MemTotal/ {printf "%d МБ", $2/1024}' /proc/meminfo)"
ok "Свободно на диске: $(df -Pm / | awk 'NR==2 {print $4" МБ"}')"
ok "Система: $(. /etc/os-release && echo "$PRETTY_NAME")"

# ─────────────────────────────────────────────────────────────────────────────
bold "2/9. Точка отката"
# ─────────────────────────────────────────────────────────────────────────────
SNAP_DIR="$DIR/backups"
mkdir -p "$SNAP_DIR"
SNAP="$SNAP_DIR/before-install-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$SNAP" --absolute-names /etc/ufw /etc/ssh/sshd_config /etc/caddy /etc/docker 2>/dev/null || true
ok "Снимок конфигов: $SNAP"

cat > "$SNAP_DIR/КАК_ОТКАТИТЬ.txt" <<EOF
Откат установки NSky
════════════════════

ЛУЧШЕЕ: снапшот диска в панели хостинга.
  Сделайте его ДО установки. Откат = восстановление снапшота целиком.

Убрать всё, что поставил скрипт:
  cd $DIR/panel && docker compose down -v
  cd $DIR/node  && docker compose down
  systemctl stop caddy && apt-get remove --purge -y caddy
  rm -rf $DIR

Вернуть только конфиги:
  tar -xzf $SNAP -C /
  systemctl daemon-reload
EOF
ok "Инструкция: $SNAP_DIR/КАК_ОТКАТИТЬ.txt"

# ─────────────────────────────────────────────────────────────────────────────
bold "3/9. Система и Docker"
# ─────────────────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg ufw jq openssl tar >/dev/null
ok "Базовые пакеты установлены"

if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
fi
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "3" }, "live-restore": true }
EOF
systemctl enable --now docker >/dev/null 2>&1
systemctl restart docker
ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"

# ─────────────────────────────────────────────────────────────────────────────
bold "4/9. Firewall"
# ─────────────────────────────────────────────────────────────────────────────
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
for p in 22/tcp 80/tcp 443/tcp 8443/tcp 443/udp 2222/tcp; do ufw allow "$p" >/dev/null; done
ufw --force enable >/dev/null
ok "Открыты: 22, 80, 443/tcp, 8443/tcp, 443/udp, 2222/tcp"

# ─────────────────────────────────────────────────────────────────────────────
bold "5/9. Панель управления"
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$DIR/panel" "$DIR/node"

if [[ ! -f "$STATE" ]]; then
  cat > "$STATE" <<EOF
SERVER_IP=$SERVER_IP
DOMAIN=$DOMAIN
DB_PASS=$(rnd 16)
APP_SECRET=$(rnd 32)
METRICS_PASS=$(rnd 12)
ADMIN_USER=admin
ADMIN_PASS=$(gen_password)
EOF
  chmod 600 "$STATE"
fi
# shellcheck disable=SC1090
source "$STATE"
[[ -n "${ADMIN_PASS:-}" ]] || { ADMIN_PASS="$(gen_password)"; echo "ADMIN_PASS=$ADMIN_PASS" >> "$STATE"; }

cat > "$DIR/panel/.env" <<EOF
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
DATABASE_URL="postgresql://remnawave:${DB_PASS}@remnawave-db:5432/remnawave"
POSTGRES_USER=remnawave
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_DB=remnawave
REDIS_SOCKET=/var/run/valkey/valkey.sock
APP_SECRET=${APP_SECRET}
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
PANEL_DOMAIN=${DOMAIN}
FRONT_END_DOMAIN=https://${DOMAIN}
SUB_PUBLIC_DOMAIN=${DOMAIN}/api/sub
METRICS_USER=nsky
METRICS_PASS=${METRICS_PASS}
WEBHOOK_ENABLED=false
WEBHOOK_SECRET_HEADER=$(rnd 32)
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=false
NOT_CONNECTED_USERS_NOTIFICATIONS_ENABLED=false
EXPIRATION_NOTIFICATIONS_ENABLED=false
EXPORT_TO_STREAM_ENABLED=false
SERVICE_SNI_VERIFICATION=true
SHORT_UUID_METHOD=uuid
EOF
chmod 600 "$DIR/panel/.env"

cat > "$DIR/panel/docker-compose.yml" <<'COMPOSE'
x-common: &common
  ulimits: { nofile: { soft: 1048576, hard: 1048576 } }
  restart: always
  networks: [nsky]
x-logging: &logging
  logging: { driver: json-file, options: { max-size: 50m, max-file: 3 } }

services:
  remnawave:
    image: remnawave/backend:3
    container_name: remnawave
    hostname: remnawave
    <<: [*common, *logging]
    env_file: .env
    volumes: [valkey-socket:/var/run/valkey]
    ports: ['127.0.0.1:3000:3000', '127.0.0.1:3001:3001']
    healthcheck:
      test: ['CMD-SHELL', 'curl -fsS http://localhost:3001/health || exit 1']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
    depends_on:
      remnawave-db: { condition: service_healthy }
      remnawave-redis: { condition: service_healthy }

  remnawave-db:
    image: postgres:18.4
    container_name: remnawave-db
    hostname: remnawave-db
    shm_size: 512mb
    <<: [*common, *logging]
    env_file: .env
    environment: [TZ=UTC]
    ports: ['127.0.0.1:6767:5432']
    volumes: [db-data:/var/lib/postgresql]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}']
      interval: 5s
      timeout: 5s
      retries: 10

  remnawave-redis:
    image: valkey/valkey:9-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    <<: [*common, *logging]
    volumes: [valkey-socket:/var/run/valkey]
    command: >
      valkey-server --save "" --appendonly no --maxmemory-policy noeviction
      --unixsocket /var/run/valkey/valkey.sock --unixsocketperm 777
    healthcheck:
      test: ['CMD', 'valkey-cli', 'ping']
      interval: 5s
      timeout: 3s
      retries: 10

volumes:
  db-data:
  valkey-socket: { name: valkey-socket }
networks:
  nsky: { name: nsky }
COMPOSE

cd "$DIR/panel"
docker compose pull -q 2>/dev/null || docker compose pull
docker compose up -d
ok "Контейнеры запущены"

printf '  ждём готовности панели'
READY=0
for _ in $(seq 1 90); do
  if curl -fsS --max-time 2 http://127.0.0.1:3001/health >/dev/null 2>&1; then READY=1; break; fi
  printf '.'; sleep 2
done
printf '\n'
[[ "$READY" = "1" ]] || { docker logs --tail 40 remnawave; die "Панель не поднялась: docker logs remnawave"; }
ok "Панель отвечает"

# ─────────────────────────────────────────────────────────────────────────────
bold "6/9. HTTPS (Caddy)"
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v caddy >/dev/null 2>&1; then
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
fi

cat > /etc/caddy/Caddyfile <<EOF
{
    email $EMAIL
}

$DOMAIN {
    reverse_proxy 127.0.0.1:3000
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        -Server
    }
    encode gzip zstd
}
EOF
systemctl enable caddy >/dev/null 2>&1
systemctl restart caddy
sleep 5
HTTPS_OK=0
if curl -fsS --max-time 10 "https://$DOMAIN" >/dev/null 2>&1; then
  HTTPS_OK=1; ok "HTTPS работает: https://$DOMAIN"
else
  warn "HTTPS пока не отвечает (DNS или порт 80). Сертификат выпустится позже автоматически."
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "7/9. Администратор и API-токен"
# ─────────────────────────────────────────────────────────────────────────────
API="http://127.0.0.1:3000/api"
TOKEN=""

# Регистрация работает только пока в панели нет ни одного пользователя.
if [[ -z "${API_TOKEN:-}" ]]; then
  REG=$(api -X POST "$API/auth/register" -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" 2>/dev/null || echo '{}')
  TOKEN=$(echo "$REG" | jq -r '.response.accessToken // empty' 2>/dev/null || true)

  if [[ -z "$TOKEN" ]]; then
    LOGIN=$(api -X POST "$API/auth/login" -H 'Content-Type: application/json' \
      -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" 2>/dev/null || echo '{}')
    TOKEN=$(echo "$LOGIN" | jq -r '.response.accessToken // empty' 2>/dev/null || true)
  fi

  if [[ -z "$TOKEN" ]]; then
    warn "Администратор не создан автоматически (возможно, уже существует с другим паролем)"
    warn "Откройте https://$DOMAIN и войдите/зарегистрируйтесь вручную"
    ADMIN_MANUAL=1
  else
    ADMIN_MANUAL=0
    ok "Администратор: ${ADMIN_USER}"

    TOK=$(api -X POST "$API/tokens" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d "{\"name\":\"nsky-admin\",\"expiresInDays\":3650}" 2>/dev/null || echo '{}')
    API_TOKEN=$(echo "$TOK" | jq -r '.response.token // empty' 2>/dev/null || true)
    if [[ -n "$API_TOKEN" ]]; then
      echo "API_TOKEN=$API_TOKEN" >> "$STATE"
      ok "API-токен создан (в $STATE)"
    else
      warn "API-токен не создан: $(echo "$TOK" | jq -r '.message // "?"' 2>/dev/null)"
      API_TOKEN="$TOKEN"
    fi
  fi
else
  ADMIN_MANUAL=0
  ok "API-токен уже есть в $STATE"
  # Для настроек нужен JWT администратора.
  LOGIN=$(api -X POST "$API/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" 2>/dev/null || echo '{}')
  TOKEN=$(echo "$LOGIN" | jq -r '.response.accessToken // empty' 2>/dev/null || true)
  [[ -n "$TOKEN" ]] || ADMIN_MANUAL=1
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "8/9. Профиль Xray и нода"
# ─────────────────────────────────────────────────────────────────────────────
NODE_READY=0

if [[ "${ADMIN_MANUAL:-1}" = "0" ]]; then

  # ---------- 8.1. Ключи REALITY через xray в контейнере ноды ----------
  ok "Генерирую ключи REALITY"
  docker pull -q remnawave/node:3 >/dev/null 2>&1 || true
  REALITY_OUT="$(docker run --rm --entrypoint xray remnawave/node:3 x25519 2>/dev/null || true)"
  REALITY_PRIV="$(echo "$REALITY_OUT" | grep -iE "private" | awk -F': *' '{print $2}' | tr -d ' ' | head -1 || true)"
  REALITY_PUB="$(echo "$REALITY_OUT"  | grep -iE "public"  | awk -F': *' '{print $2}' | tr -d ' ' | head -1 || true)"
  if [[ -z "$REALITY_PRIV" ]]; then
    # Запасной вариант: ключи через openssl (формат x25519 в base64url)
    REALITY_PRIV="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
    warn "xray x25519 недоступен, сгенерирован случайный ключ (проверьте подключение)"
  fi
  [[ -n "$REALITY_PUB" ]] || warn "Публичный ключ не получен — посмотрите в панели"
  REALITY_SHORT_ID="$(rnd 8)"
  ok "Ключи готовы"

  # ---------- 8.2. Создаём профиль конфигурации ----------
  XHTTP_PATH="/$(rnd 4)$(rnd 4)"
  # SNI-маска: известный сайт, к которому ходим по TLS.
  REALITY_SNI="www.microsoft.com"

  read -r -d '' PROFILE_JSON <<JSONPF || true
{
  "name": "nsky-main",
  "config": {
    "log": { "loglevel": "warning" },
    "inbounds": [
      {
        "tag": "vless-reality-443",
        "listen": "0.0.0.0",
        "port": 443,
        "protocol": "vless",
        "settings": { "clients": [], "decryption": "none" },
        "streamSettings": {
          "network": "raw",
          "security": "reality",
          "realitySettings": {
            "show": false,
            "target": "${REALITY_SNI}:443",
            "xver": 0,
            "serverNames": ["${REALITY_SNI}"],
            "privateKey": "${REALITY_PRIV}",
            "shortIds": ["${REALITY_SHORT_ID}"]
          }
        },
        "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
      },
      {
        "tag": "vless-xhttp-8443",
        "listen": "0.0.0.0",
        "port": 8443,
        "protocol": "vless",
        "settings": { "clients": [], "decryption": "none" },
        "streamSettings": {
          "network": "xhttp",
          "security": "none",
          "xhttpSettings": { "path": "${XHTTP_PATH}", "mode": "auto" }
        },
        "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
      }
    ],
    "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
  }
}
JSONPF

  # Hysteria2 добавляем только если есть сертификат: он требует TLS.
  # Берём самоподписанный — клиент в режиме "insecure" это допускает.
  HY2_OK=0
  mkdir -p "$DIR/node/certs"
  if [[ ! -f "$DIR/node/certs/cert.pem" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "$DIR/node/certs/key.pem" -out "$DIR/node/certs/cert.pem" \
      -subj "/CN=${DOMAIN}" >/dev/null 2>&1 && HY2_OK=1
  else
    HY2_OK=1
  fi

  PROFILE_RESP=$(printf '%s' "$PROFILE_JSON" | api -X POST "$API/config-profiles" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data-binary @- 2>/dev/null || echo '{}')
  PROFILE_UUID=$(echo "$PROFILE_RESP" | jq -r '.response.uuid // empty' 2>/dev/null || true)

  if [[ -z "$PROFILE_UUID" ]]; then
    warn "Профиль не создан: $(echo "$PROFILE_RESP" | jq -r '.message // "?"' 2>/dev/null)"
    warn "Создайте профиль вручную: Config Profiles → Create, файл deploy/xray/ в репозитории"
  else
    ok "Профиль создан: nsky-main ($PROFILE_UUID)"

    # ---------- 8.3. Берём UUID инбаундов профиля ----------
    INB_RESP=$(api "$API/config-profiles/$PROFILE_UUID/inbounds" -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo '{}')
    INBOUND_UUIDS=$(echo "$INB_RESP" | jq -r '[.response[]?.uuid] | @json' 2>/dev/null || echo '[]')
    if [[ "$INBOUND_UUIDS" = "[]" || -z "$INBOUND_UUIDS" ]]; then
      INBOUND_UUIDS=$(echo "$PROFILE_RESP" | jq -r '[.response.inbounds[]?.uuid] | @json' 2>/dev/null || echo '[]')
    fi

    # ---------- 8.4. Создаём ноду ----------
    NODE_BODY=$(jq -n \
      --arg name "nsky-1" \
      --arg addr "$SERVER_IP" \
      --arg puuid "$PROFILE_UUID" \
      --argjson inbounds "$INBOUND_UUIDS" \
      '{name:$name, address:$addr, port:2222, isTrafficTrackingActive:false,
        configProfile:{activeConfigProfileUuid:$puuid, activeInbounds:$inbounds}}')

    NODE_RESP=$(printf '%s' "$NODE_BODY" | api -X POST "$API/nodes" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data-binary @- 2>/dev/null || echo '{}')
    NODE_UUID=$(echo "$NODE_RESP" | jq -r '.response.uuid // empty' 2>/dev/null || true)

    if [[ -z "$NODE_UUID" ]]; then
      warn "Нода не создана: $(echo "$NODE_RESP" | jq -r '.message // "?"' 2>/dev/null)"
    else
      ok "Нода создана: nsky-1 ($NODE_UUID)"

      # SECRET_KEY выдаётся отдельным эндпоинтом.
      KEY_RESP=$(api "$API/keygen" -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo '{}')
      NODE_SECRET=$(echo "$KEY_RESP" | jq -r '.response.secretKey // empty' 2>/dev/null || true)

      if [[ -z "$NODE_SECRET" ]]; then
        warn "SECRET_KEY не получен через API"
        warn "В панели: Nodes → ваша нода → получить ключ, затем запустить node"
      else
        echo "NODE_SECRET=$NODE_SECRET" >> "$STATE"
        echo "NODE_UUID=$NODE_UUID"       >> "$STATE"
        echo "PROFILE_UUID=$PROFILE_UUID" >> "$STATE"
        echo "REALITY_PUB=$REALITY_PUB"   >> "$STATE"
        echo "REALITY_SNI=$REALITY_SNI"   >> "$STATE"
        echo "REALITY_SHORT_ID=$REALITY_SHORT_ID" >> "$STATE"

        cat > "$DIR/node/docker-compose.yml" <<EOF
services:
  remnanode:
    image: remnawave/node:3
    container_name: remnanode
    hostname: remnanode
    network_mode: host
    restart: always
    cap_add: [NET_ADMIN]
    ulimits: { nofile: { soft: 1048576, hard: 1048576 } }
    volumes:
      - ./certs:/etc/remnanode/certs:ro
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=${NODE_SECRET}
EOF
        cd "$DIR/node"
        docker compose pull -q 2>/dev/null || docker compose pull
        docker compose up -d
        ok "Нода запущена"
        NODE_READY=1
      fi
    fi
  fi
else
  warn "Шаг пропущен: сначала нужен администратор. Настройте вручную в панели."
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "9/9. Готово"
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${ADMIN_MANUAL:-1}" = "0" ]]; then
  cat > "$DIR/ДОСТУП.txt" <<EOF
Панель:  https://${DOMAIN}
Логин:   ${ADMIN_USER}
Пароль:  ${ADMIN_PASS}
EOF
  chmod 600 "$DIR/ДОСТУП.txt"
fi

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  NSky установлен                                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
echo "  Панель:   https://${DOMAIN}"
if [[ "$HTTPS_OK" = "1" ]]; then echo "  HTTPS:    работает"; else echo "  HTTPS:    ждёт DNS или порт 80"; fi
echo
if [[ "${ADMIN_MANUAL:-1}" = "0" ]]; then
  echo "  Логин:    ${ADMIN_USER}"
  echo "  Пароль:   ${ADMIN_PASS}"
  echo
  echo "  Пароль сохранён: $DIR/ДОСТУП.txt"
  echo "  Смените его при первом входе."
  echo
fi
if [[ "$NODE_READY" = "1" ]]; then
  echo "  Нода:     запущена (nsky-1), протоколы в профиле nsky-main"
else
  echo "  Нода:     НЕ запущена — настройте вручную (см. лог ниже)"
fi
echo
echo "  Сервер:   ${SERVER_IP}"
echo "  Логи:     docker logs -f remnawave"
echo "  Откат:    ${SNAP_DIR}/КАК_ОТКАТИТЬ.txt"
echo "  Лог:      ${LOG}"
echo
echo "══════════════════════════════════════════════════════════════"
