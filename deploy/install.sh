#!/usr/bin/env bash
#
# NSky — установка VPN-сервера одной командой.
#
# Ставит на чистый Ubuntu Server 24.04:
#   • Remnawave Panel  — управление пользователями и подписками
#   • Remnawave Node   — Xray, через который ходит трафик (VLESS+REALITY, XHTTP, Hysteria2)
#   • Caddy            — HTTPS для панели и страницы подписки (сертификат сам)
#   • UFW              — firewall: открыто только нужное
#
# Перед изменениями делает снимок конфигурации, чтобы можно было откатиться.
#
# Использование:
#   bash install.sh panel.<домен> <email-для-TLS>
# Пример:
#   bash install.sh panel.rknmrz.xyz admin@example.com
#
# Скрипт идемпотентен: повторный запуск не ломает уже установленное.

set -Eeuo pipefail

PANEL_DOMAIN="${1:-}"
TLS_EMAIL="${2:-}"
INSTALL_DIR="/opt/nsky"
BACKUP_DIR="/opt/nsky-backups"

log()  { printf '\033[1;34m[NSky]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[NSky]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[NSky]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите от root:  sudo bash install.sh ..."
[[ -n "$PANEL_DOMAIN" ]] || die "Укажите домен панели: bash install.sh panel.example.com admin@example.com"
[[ -n "$TLS_EMAIL" ]] || die "Укажите email для Let's Encrypt: bash install.sh panel.example.com admin@example.com"

# ─────────────────────────────────────────────────────────────────────────────
# 0. Снимок текущего состояния (точка отката)
# ─────────────────────────────────────────────────────────────────────────────
snapshot() {
  mkdir -p "$BACKUP_DIR"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local out="$BACKUP_DIR/$stamp.tar.gz"

  log "Создаю точку отката: $out"
  local items=()
  for p in /etc/nftables.conf /etc/ufw /etc/ssh/sshd_config /etc/systemd/system "$INSTALL_DIR"; do
    [[ -e "$p" ]] && items+=("$p")
  done

  if [[ ${#items[@]} -gt 0 ]]; then
    tar -czf "$out" --absolute-names "${items[@]}" 2>/dev/null || true
    chmod 600 "$out"
    log "Снимок сохранён: $(du -h "$out" | cut -f1)"
  fi

  # Список установленных пакетов — чтобы понимать, что появилось.
  dpkg -l > "$BACKUP_DIR/$stamp.packages.txt" 2>/dev/null || true

  # Если это VPS с поддержкой снапшотов — лучший откат делать там (см. docs/СЕРВЕР_УСТАНОВКА.md).
  cat > "$BACKUP_DIR/КАК_ОТКАТИТЬ.txt" <<EOF
Точка отката от $stamp

Вариант 1 (лучший): снапшот диска в панели хостинга.
  Сделайте его ДО установки: хостинг → Snapshots → Create.
  Откат: восстановление снапшота целиком.

Вариант 2: файлы из этого архива
  tar -xzf $out -C /
  systemctl daemon-reload
  ufw --force enable

Вариант 3: полное удаление
  cd $INSTALL_DIR && docker compose down -v
  rm -rf $INSTALL_DIR $BACKUP_DIR
  apt-get remove --purge -y caddy
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Система
# ─────────────────────────────────────────────────────────────────────────────
prepare_system() {
  log "Обновляю систему и ставлю зависимости"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg ufw jq openssl tar >/dev/null

  if ! command -v docker >/dev/null 2>&1; then
    log "Ставлю Docker"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
  else
    log "Docker уже установлен"
  fi

  # Docker пишет логи бесконечно, если не ограничить — на VPS это съедает диск.
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "live-restore": true
}
EOF
  systemctl enable --now docker >/dev/null 2>&1
  systemctl restart docker
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Firewall — только нужные порты
# ─────────────────────────────────────────────────────────────────────────────
setup_firewall() {
  log "Настраиваю firewall"
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  ufw allow 22/tcp comment 'SSH'        >/dev/null
  ufw allow 80/tcp comment 'ACME/Caddy' >/dev/null
  ufw allow 443/tcp comment 'HTTPS/VLESS' >/dev/null
  ufw allow 8443/tcp comment 'VLESS+XHTTP' >/dev/null
  ufw allow 443/udp comment 'Hysteria2'   >/dev/null
  ufw allow 2222/tcp comment 'Remnawave node control (только для панели)' >/dev/null

  ufw --force enable >/dev/null
  ufw status numbered | sed 's/^/    /'
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Файлы панели
# ─────────────────────────────────────────────────────────────────────────────
write_panel() {
  log "Готовлю $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/panel" "$INSTALL_DIR/node" "$INSTALL_DIR/caddy"

  gen() { openssl rand -hex "$1"; }

  if [[ ! -f "$INSTALL_DIR/panel/.env" ]]; then
    cat > "$INSTALL_DIR/panel/.env" <<EOF
### APP ###
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1

### DATABASE ###
DATABASE_URL="postgresql://remnawave:$(gen 16)@remnawave-db:5432/remnawave"
POSTGRES_USER=remnawave
POSTGRES_PASSWORD=$(gen 16)
POSTGRES_DB=remnawave

### REDIS ###
REDIS_SOCKET=/var/run/valkey/valkey.sock

### SECRETS ###
APP_SECRET=$(gen 32)

### TELEGRAM ###
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false

### DOMAINS ###
PANEL_DOMAIN=$PANEL_DOMAIN
FRONT_END_DOMAIN=https://$PANEL_DOMAIN
SUB_PUBLIC_DOMAIN=$PANEL_DOMAIN/api/sub

### PROMETHEUS ###
METRICS_USER=nsky
METRICS_PASS=$(gen 12)

### WEBHOOKS ###
WEBHOOK_ENABLED=false
WEBHOOK_SECRET_HEADER=$(gen 32)

### NOTIFICATIONS ###
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=false
NOT_CONNECTED_USERS_NOTIFICATIONS_ENABLED=false
EXPIRATION_NOTIFICATIONS_ENABLED=false
EXPORT_TO_STREAM_ENABLED=false

### SNI ###
SERVICE_SNI_VERIFICATION=true

### SHORT UUID ###
SHORT_UUID_METHOD=uuid
EOF
    chmod 600 "$INSTALL_DIR/panel/.env"
    log "Секреты сгенерированы автоматически"
  else
    log ".env уже существует — не трогаю"
  fi

  # DATABASE_URL и POSTGRES_PASSWORD должны совпадать: берём одно значение.
  local dbpass; dbpass="$(grep -m1 '^POSTGRES_PASSWORD=' "$INSTALL_DIR/panel/.env" | cut -d= -f2-)"
  sed -i "s|^DATABASE_URL=.*|DATABASE_URL=\"postgresql://remnawave:${dbpass}@remnawave-db:5432/remnawave\"|" \
    "$INSTALL_DIR/panel/.env"

  cat > "$INSTALL_DIR/panel/docker-compose.yml" <<'EOF'
x-common: &common
  ulimits:
    nofile: { soft: 1048576, hard: 1048576 }
  restart: always
  networks: [nsky]

x-logging: &logging
  logging:
    driver: json-file
    options: { max-size: 50m, max-file: 3 }

services:
  remnawave:
    image: remnawave/backend:3
    container_name: remnawave
    hostname: remnawave
    <<: [*common, *logging]
    env_file: .env
    volumes: [valkey-socket:/var/run/valkey]
    ports:
      - 127.0.0.1:3000:3000
      - 127.0.0.1:3001:3001
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
    environment:
      - TZ=UTC
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
      valkey-server
      --save ""
      --appendonly no
      --maxmemory-policy noeviction
      --unixsocket /var/run/valkey/valkey.sock
      --unixsocketperm 777
    healthcheck:
      test: ['CMD', 'valkey-cli', 'ping']
      interval: 5s
      timeout: 3s
      retries: 10

volumes:
  db-data:
  valkey-socket:
    name: valkey-socket

networks:
  nsky:
    name: nsky
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Caddy — HTTPS для панели
# ─────────────────────────────────────────────────────────────────────────────
write_caddy() {
  log "Настраиваю Caddy (HTTPS)"
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
    email $TLS_EMAIL
}

$PANEL_DOMAIN {
    # Панель (API + фронтенд) и страница подписки
    reverse_proxy 127.0.0.1:3000

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }

    encode gzip zstd
    log {
        output file /var/log/caddy/panel.log {
            roll_size 20mb
            roll_keep 5
        }
    }
}
EOF
  systemctl enable caddy >/dev/null 2>&1
  systemctl restart caddy
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Запуск панели
# ─────────────────────────────────────────────────────────────────────────────
start_panel() {
  log "Запускаю панель"
  cd "$INSTALL_DIR/panel"
  docker compose pull -q 2>/dev/null || docker compose pull
  docker compose up -d

  log "Жду готовности панели (до 2 минут)"
  for i in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:3001/health >/dev/null 2>&1; then
      log "Панель отвечает"
      return 0
    fi
    sleep 2
  done
  warn "Панель не ответила за 2 минуты. Проверьте: docker compose -f $INSTALL_DIR/panel/docker-compose.yml logs"
}

# ─────────────────────────────────────────────────────────────────────────────
main() {
  log "Домен панели: $PANEL_DOMAIN"
  log "Email для TLS: $TLS_EMAIL"

  snapshot
  prepare_system
  setup_firewall
  write_panel
  write_caddy
  start_panel

  local ip; ip="$(curl -fsS -4 https://ifconfig.me 2>/dev/null || echo 'IP сервера')"

  cat <<EOF

──────────────────────────────────────────────────────────
 Готово. Панель установлена.

 Откройте:  https://$PANEL_DOMAIN
 Первый вход: создайте администратора на экране регистрации.

 Дальше (в панели):
   1. Settings → API Tokens → создать токен (сохраните, показывается один раз)
   2. Nodes → Create Node → скопировать SECRET_KEY
   3. На этом же сервере выполнить (см. node/docker-compose.yml):
        cd $INSTALL_DIR/node && SECRET_KEY=<вставьте> docker compose up -d
   4. Config Profiles → импортировать профиль Xray (deploy/xray/)

 Сервер: $ip
 Логи панели: docker logs -f remnawave
 Откат: см. $BACKUP_DIR/КАК_ОТКАТИТЬ.txt
──────────────────────────────────────────────────────────
EOF
}

main "$@"
