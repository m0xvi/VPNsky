#!/usr/bin/env bash
#
# NSky — ПОЛНАЯ автоматическая установка VPN-сервера.
#
# Одна команда ставит и настраивает всё:
#   • Docker, firewall
#   • Remnawave Panel + Postgres + Valkey
#   • Caddy с автоматическим HTTPS (Let's Encrypt)
#   • Remnawave Node (Xray: VLESS+REALITY, XHTTP, Hysteria2)
#   • суперадмина панели с готовым паролем
#   • API-токен
#   • ноду, привязанную к панели
#   • конфиг-профиль с тремя протоколами
#
# На выходе печатает адрес панели, логин, пароль и ссылку-приглашение для клиента.
#
# Использование:
#   bash setup-server.sh <домен> <email>
#
# Пример:
#   bash setup-server.sh oijas.rknmrz.xyz admin@example.com
#
# Требования: чистый Ubuntu 22.04/24.04, root, домен уже указывает на этот сервер.

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

# ─────────────────────────────────────────────────────────────────────────────
bold "1/9. Проверка сервера"
# ─────────────────────────────────────────────────────────────────────────────
SERVER_IP="$(curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null || echo '')"
[[ -n "$SERVER_IP" ]] || die "Нет доступа в интернет с сервера"
ok "IP сервера: $SERVER_IP"

RESOLVED="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1)"
if [[ "$RESOLVED" != "$SERVER_IP" ]]; then
  warn "Домен $DOMAIN указывает на '$RESOLVED', а IP сервера '$SERVER_IP'"
  warn "HTTPS не выпустится, пока DNS не совпадёт. Продолжаю, но Caddy может ругаться."
else
  ok "Домен $DOMAIN указывает на этот сервер"
fi

TOTAL_RAM=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
ok "Память: ${TOTAL_RAM} МБ"
[[ "$TOTAL_RAM" -lt 900 ]] && warn "Меньше 1 ГБ: панель может работать медленно"

FREE_DISK=$(df -Pm / | awk 'NR==2 {print $4}')
ok "Свободно на диске: ${FREE_DISK} МБ"
[[ "$FREE_DISK" -lt 4000 ]] && warn "Мало места: рекомендуется 10 ГБ+"

# ─────────────────────────────────────────────────────────────────────────────
bold "2/9. Точка отката"
# ─────────────────────────────────────────────────────────────────────────────
SNAP_DIR="$DIR/backups"
mkdir -p "$SNAP_DIR"
SNAP="$SNAP_DIR/before-install-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$SNAP" --absolute-names /etc/ufw /etc/ssh/sshd_config /etc/caddy /etc/docker 2>/dev/null || true
ok "Снимок конфигов: $SNAP ($(du -h "$SNAP" 2>/dev/null | cut -f1))"
cat > "$SNAP_DIR/КАК_ОТКАТИТЬ.txt" <<EOF
Откат установки NSky

ЛУЧШЕЕ: снапшот диска в панели хостинга (сделайте его ДО установки).
  Откат = восстановление снапшота целиком.

Снять всё, что поставил этот скрипт:
  cd $DIR/panel && docker compose down -v
  systemctl stop caddy; apt-get remove --purge -y caddy
  rm -rf $DIR

Вернуть только конфиги:
  tar -xzf $SNAP -C /
  systemctl daemon-reload
EOF
ok "Инструкция по откату: $SNAP_DIR/КАК_ОТКАТИТЬ.txt"

# ─────────────────────────────────────────────────────────────────────────────
bold "3/9. Система и Docker"
# ─────────────────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg ufw jq openssl tar qrencode >/dev/null 2>&1 || \
  apt-get install -y -qq curl ca-certificates gnupg ufw jq openssl tar >/dev/null
ok "Базовые пакеты"

if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
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
ufw allow 22/tcp   >/dev/null
ufw allow 80/tcp   >/dev/null
ufw allow 443/tcp  >/dev/null
ufw allow 8443/tcp >/dev/null
ufw allow 443/udp  >/dev/null
ufw allow 2222/tcp >/dev/null
ufw --force enable >/dev/null
ok "Открыты: 22, 80, 443/tcp, 8443/tcp, 443/udp, 2222/tcp"

# ─────────────────────────────────────────────────────────────────────────────
bold "5/9. Панель управления"
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$DIR/panel" "$DIR/node"

rnd() { openssl rand -hex "$1"; }

if [[ ! -f "$STATE" ]]; then
  cat > "$STATE" <<EOF
SERVER_IP=$SERVER_IP
DOMAIN=$DOMAIN
DB_PASS=$(rnd 16)
APP_SECRET=$(rnd 32)
METRICS_PASS=$(rnd 12)
ADMIN_USER=admin
ADMIN_PASS=$(rnd 20)Ah1
EOF
  chmod 600 "$STATE"
fi
# shellcheck disable=SC1090
source "$STATE"

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
for i in $(seq 1 90); do
  if curl -fsS --max-time 2 http://127.0.0.1:3001/health >/dev/null 2>&1; then READY=1; break; fi
  printf '.'; sleep 2
done
printf '\n'
[[ "$READY" = "1" ]] || { docker logs --tail 40 remnawave; die "Панель не поднялась. Лог: docker logs remnawave"; }
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
if curl -fsS --max-time 10 "https://$DOMAIN" >/dev/null 2>&1; then
  ok "HTTPS работает: https://$DOMAIN"
  HTTPS_OK=1
else
  warn "HTTPS пока не отвечает (DNS или 80 порт). Панель доступна, сертификат выпустится позже."
  HTTPS_OK=0
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "7/9. Администратор и API-токен"
# ─────────────────────────────────────────────────────────────────────────────
API="http://127.0.0.1:3000"

REG=$(curl -fsS -X POST "$API/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" 2>/dev/null || echo '{}')
TOKEN=$(echo "$REG" | jq -r '.response.accessToken // empty' 2>/dev/null || true)

if [[ -z "$TOKEN" ]]; then
  LOGIN=$(curl -fsS -X POST "$API/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" 2>/dev/null || echo '{}')
  TOKEN=$(echo "$LOGIN" | jq -r '.response.accessToken // empty' 2>/dev/null || true)
fi

if [[ -z "$TOKEN" ]]; then
  warn "Не удалось создать администратора автоматически"
  warn "Откройте https://$DOMAIN и зарегистрируйтесь вручную"
  ADMIN_MANUAL=1
else
  ok "Администратор создан: ${ADMIN_USER}"
  ADMIN_MANUAL=0
  # Долгоживущий токен для API (нужен клиенту-админке)
  API_TOKEN_JSON=$(curl -fsS -X POST "$API/api/tokens" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"tokenName":"nsky-admin","expiresInDays":3650}' 2>/dev/null || echo '{}')
  API_TOKEN=$(echo "$API_TOKEN_JSON" | jq -r '.response.token // empty' 2>/dev/null || true)
  [[ -n "$API_TOKEN" ]] && ok "API-токен создан (хранится в $STATE)"
  [[ -n "$API_TOKEN" ]] && echo "API_TOKEN=$API_TOKEN" >> "$STATE"
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "8/9. Нода и профиль Xray"
# ─────────────────────────────────────────────────────────────────────────────
NODE_READY=0
if [[ "$ADMIN_MANUAL" = "0" ]]; then
  NODE_JSON=$(curl -fsS -X POST "$API/api/nodes" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"name\":\"nsky-nl-1\",\"address\":\"${SERVER_IP}\",\"port\":2222,\"isTrafficTrackingActive\":false}" 2>/dev/null || echo '{}')

  NODE_SECRET=$(echo "$NODE_JSON" | jq -r '.response.secretKey // .response.secret // empty' 2>/dev/null || true)
  NODE_UUID=$(echo "$NODE_JSON" | jq -r '.response.uuid // empty' 2>/dev/null || true)

  if [[ -n "$NODE_SECRET" ]]; then
    echo "NODE_SECRET=$NODE_SECRET" >> "$STATE"
    echo "NODE_UUID=$NODE_UUID" >> "$STATE"

    cat > "$DIR/node/docker-compose.yml" <<EOF
services:
  remnanode:
    image: remnawave/node:3
    container_name: remnanode
    hostname: remnanode
    network_mode: host
    restart: always
    cap_add: [NET_ADMIN]
    ulimits:
      nofile: { soft: 1048576, hard: 1048576 }
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=${NODE_SECRET}
EOF
    cd "$DIR/node"
    docker compose pull -q 2>/dev/null || docker compose pull
    docker compose up -d
    ok "Нода запущена (nsky-nl-1)"
    NODE_READY=1
  else
    warn "Нода не создана через API: $(echo "$NODE_JSON" | jq -r '.message // "неизвестно"' 2>/dev/null)"
    warn "Создайте вручную: Nodes → Create Node, затем запустите node/docker-compose.yml"
  fi
else
  warn "Нода пропущена: сначала нужен администратор"
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "9/9. Итог"
# ─────────────────────────────────────────────────────────────────────────────
PROTO_LINES=""
if [[ "$NODE_READY" = "1" ]]; then
  PROTO_LINES="  Протоколы (панель → Config Profiles):\n    • VLESS + REALITY     443/tcp  — основной\n    • VLESS + XHTTP       8443/tcp — резерв\n    • Hysteria2           443/udp  — для мобильных сетей"
else
  PROTO_LINES="  Протоколы: создайте профиль в панели (файл deploy/xray/ в репозитории)"
fi

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  NSky установлен                                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
echo "  Панель:        https://${DOMAIN}"
if [[ "$HTTPS_OK" = "1" ]]; then
  echo "  Статус HTTPS:  работает"
else
  echo "  Статус HTTPS:  ждёт DNS или порт 80"
fi
echo
if [[ "$ADMIN_MANUAL" = "0" ]]; then
  echo "  Логин:         ${ADMIN_USER}"
  echo "  Пароль:        ${ADMIN_PASS}"
  echo
  echo "  Смените пароль при первом входе."
  echo "  Секреты сохранены: ${STATE}"
  echo
fi
printf "%b\n" "$PROTO_LINES"
echo
echo "  Сервер:        ${SERVER_IP}"
echo "  Логи:          docker logs -f remnawave"
echo "  Откат:         ${SNAP_DIR}/КАК_ОТКАТИТЬ.txt"
echo "  Лог:           ${LOG}"
echo
echo "══════════════════════════════════════════════════════════════"
echo

if [[ "$ADMIN_MANUAL" = "0" ]]; then
  echo "Панель: https://${DOMAIN}"  > "$DIR/ДОСТУП.txt"
  echo "Логин: ${ADMIN_USER}"      >> "$DIR/ДОСТУП.txt"
  echo "Пароль: ${ADMIN_PASS}"     >> "$DIR/ДОСТУП.txt"
  chmod 600 "$DIR/ДОСТУП.txt"
fi
