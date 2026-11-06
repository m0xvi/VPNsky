#!/usr/bin/env bash
#
# NSky — установка VPN-сервера с нуля на чистом Ubuntu 22.04 / 24.04.
#
# Один файл делает всё:
#   1.  проверка сервера и DNS
#   2.  точка восстановления (снимок конфигов + инструкция откатa)
#   3.  система, Docker, firewall
#   4.  панель Remnawave (Postgres + Valkey), миграции и seed
#   5.  Caddy с HTTPS (Let's Encrypt)
#   6.  администратор, API-токен
#   7.  профиль Xray: VLESS+REALITY, VLESS+XHTTP, Hysteria2
#   8.  хосты (без них подписка пустая)
#   9.  нода + запуск + ожидание подключения
#   10. внутренний сквад, тестовый пользователь, печать ссылки подписки
#
# Использование:
#   bash nsky-install.sh <домен> <email>            # установка
#   bash nsky-install.sh <домен> <email> --wipe     # снести и поставить заново
#   bash nsky-install.sh <домен> <email> --panel-ip 1.2.3.4,5.6.7.0/24  # панель только с IP офиса
#   bash nsky-install.sh <домен> <email> --cascade 5.6.7.8         # каскад через русский VPS
#   bash nsky-install.sh <домен> <email> --cascade-remove          # выключить каскад
#   bash nsky-install.sh <домен> <email> --check    # только диагностика
#
# Пример:
#   bash nsky-install.sh oijas.rknmrz.xyz admin@example.com
#
# Повторный запуск без --wipe безопасен: пароли и данные не перезаписываются,
# профиль обновляется по тегам инбаундов (UUID сохраняются), нода не пересоздаётся.

set -Eeuo pipefail

# ─── аргументы ───────────────────────────────────────────────────────────────
DOMAIN="${1:-}"
EMAIL="${2:-}"
MODE="install"
PANEL_PORT_ARG=""
PANEL_ALLOW_FROM_ARG=""
CASCADE_ARG=""
CASCADE_REMOVE="0"
_args=("$@")
for (( _i = 2; _i < ${#_args[@]}; _i++ )); do
  case "${_args[_i]}" in
    --wipe)       MODE="wipe" ;;
    --check)      MODE="check" ;;
    --panel-port) PANEL_PORT_ARG="${_args[_i+1]}"; (( _i++ )) ;;
    --panel-ip)   PANEL_ALLOW_FROM_ARG="${_args[_i+1]}"; (( _i++ )) ;;
    --cascade)    CASCADE_ARG="${_args[_i+1]}"; (( _i++ )) ;;
    --cascade-remove) CASCADE_REMOVE="1" ;;
  esac
done

DIR="/opt/nsky"
STATE="$DIR/install-state.env"
LOG="$DIR/install.log"
PROJECT="nsky"
PROJECT_NODE="nsky-node"
NSKY_VERSION="2026-11-06.6"

# Порты. 443/tcp — публичная подписка для клиентов. Панель управления
# живёт на отдельном порту, доступном только с IP офиса:
#   REALITY   → 8443/tcp
#   XHTTP     → 2053/tcp
#   Hysteria2 → 443/udp   (UDP с Caddy не конфликтует)
#   PANEL     → 8444/tcp  (только с IP офиса, см. --panel-ip)
REALITY_PORT=8443
XHTTP_PORT=2053
HY2_PORT=443
NODE_PORT=2222
PANEL_PORT="${PANEL_PORT_ARG:-}"
PANEL_ALLOW_FROM="${PANEL_ALLOW_FROM_ARG:-}"
# PANEL_PORT / PANEL_ALLOW_FROM подхватываются из состояния ниже,
# после определения state_get (STATE доступна уже сейчас).

REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"

# ─── вывод ───────────────────────────────────────────────────────────────────
mkdir -p "$DIR"
exec > >(tee -a "$LOG") 2>&1

bold() { printf '\n\033[1;36m══ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; }
die()  { bad "$*"; printf '\n  Полный лог: %s\n\n' "$LOG"; exit 1; }

trap 'bad "Прервано на строке $LINENO. Лог: $LOG"' ERR

[[ $EUID -eq 0 ]] || die "Запустите от root:  sudo bash $0 <домен> <email>"
[[ -n "$DOMAIN" ]] || die "Использование: bash $0 <домен> <email> [--wipe|--check] \\n           [--panel-port <порт>] [--panel-ip <IP/CIDR,...>]"

# ─── утилиты ─────────────────────────────────────────────────────────────────
rnd() { openssl rand -hex "$1"; }

# Панель требует пароль 24+ символа, верхний/нижний регистр и цифры.
gen_password() { printf '%sAa9' "$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"; }

# Панель принимает JWT только с этим заголовком, иначе 403
# "For API requests you must create own API-token".
# См. src/common/guards/jwt-guards/def-jwt-guard.ts
CLIENT_HDR='X-Remnawave-Client-Type: browser'

API="http://127.0.0.1:3000/api"

# Панель проверяет каждый запрос (src/common/middlewares/proxy-check.middleware.ts):
# если нет X-Forwarded-Proto: https, соединение просто обрывается — без ответа
# и без кода. Поэтому все обращения к API идут с этими двумя заголовками.
api() {
  curl -sS --max-time 40 \
    -H 'x-forwarded-for: 127.0.0.1' \
    -H 'x-forwarded-proto: https' \
    "$@"
}

state_get() { [[ -f "$STATE" ]] && sed -n "s/^$1=//p" "$STATE" | head -1 || true; }
state_set() {
  [[ -f "$STATE" ]] || return 0
  sed -i "/^$1=/d" "$STATE"
  printf '%s=%s\n' "$1" "$2" >> "$STATE"
}

# Панель: порт и список IP офиса из прошлого запуска (если не задано заново).
[[ -z "$PANEL_PORT" ]] && PANEL_PORT="$(state_get PANEL_PORT)"
[[ -z "$PANEL_PORT" ]] && PANEL_PORT=8444
[[ -z "$PANEL_ALLOW_FROM" ]] && PANEL_ALLOW_FROM="$(state_get PANEL_ALLOW_FROM)"
[[ -n "$PANEL_ALLOW_FROM" ]] || PANEL_ALLOW_FROM=""
# Секретный сегмент в URL подписки: прячет известный сканерам путь /api/sub.
SUB_SECRET="$(state_get SUB_SECRET)"
# Каскад: IP русского релея (--cascade). Пусто = каскада нет.
CASCADE_IP="${CASCADE_ARG:-}"
[[ -n "$CASCADE_IP" || "$CASCADE_REMOVE" == "1" ]] || CASCADE_IP="$(state_get CASCADE_IP)"


# ─────────────────────────────────────────────────────────────────────────────
bold "1/10. Проверка сервера"
# ─────────────────────────────────────────────────────────────────────────────
info "Версия установщика: $NSKY_VERSION"
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ok "Система: ${PRETTY_NAME:-неизвестно}" ;;
  *) warn "Проверено на Ubuntu/Debian, у вас ${PRETTY_NAME:-неизвестно} — продолжаю" ;;
esac

SERVER_IP="$(curl -4 -fsS --max-time 15 https://api.ipify.org 2>/dev/null \
          || curl -4 -fsS --max-time 15 https://ifconfig.me 2>/dev/null || true)"
[[ -n "$SERVER_IP" ]] || die "Нет доступа в интернет с сервера"
ok "IP сервера: $SERVER_IP"

RESOLVED="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)"
if [[ "$RESOLVED" != "$SERVER_IP" ]]; then
  warn "Домен $DOMAIN указывает на '${RESOLVED:-ничего}', а IP сервера $SERVER_IP"
  warn "HTTPS не выпустится, пока DNS не совпадёт. Всё остальное установится."
  DNS_OK=0
else
  ok "Домен $DOMAIN указывает на этот сервер"
  DNS_OK=1
fi

MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
DISK_MB=$(df -Pm / | awk 'NR==2 {print $4}')
ok "Память: ${MEM_MB} МБ, свободно на диске: ${DISK_MB} МБ"
(( MEM_MB >= 900 )) || warn "Меньше 900 МБ памяти — панель может не подняться"
(( DISK_MB >= 5000 )) || warn "Меньше 5 ГБ диска — может не хватить на образы"

# SSH-порт нельзя терять при настройке firewall.
SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"
SSH_PORT="${SSH_PORT:-22}"
ok "SSH порт: $SSH_PORT"

# ─────────────────────────────────────────────────────────────────────────────
# Режим --check: только диагностика, ничего не меняем.
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "check" ]]; then
  bold "Диагностика NSky"
  API="http://127.0.0.1:3000/api"
  CHK_TOKEN="$(state_get API_TOKEN)"

  chk() { printf '  %-28s %s\n' "$1" "$2"; }

  printf '\n── Система ─────────────────────────────────\n'
  chk "Домен" "$DOMAIN"
  chk "DNS указывает на" "${RESOLVED:-ничего}$([[ "$DNS_OK" == "1" ]] && echo ' ✓' || echo ' ✗ не совпадает с IP')"
  chk "IP сервера" "$SERVER_IP"
  chk "Память / диск" "${MEM_MB} МБ / ${DISK_MB} МБ"
  chk "Docker" "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d , || echo 'нет')"

  printf '\n── Контейнеры ──────────────────────────────\n'
  if command -v docker >/dev/null 2>&1; then
    docker ps --format '  {{.Names}}  {{.Status}}' 2>/dev/null || echo "  нет доступа к docker"
  else
    echo "  docker не установлен"
  fi

  printf '\n── Панель ──────────────────────────────────\n'
  if curl -fsS --max-time 5 http://127.0.0.1:3001/health >/dev/null 2>&1; then
    chk "Локальный health" "✓ отвечает"
  else
    chk "Локальный health" "✗ не отвечает (docker logs remnawave)"
  fi
  if curl -fsS --max-time 10 "https://$DOMAIN:$PANEL_PORT" >/dev/null 2>&1; then
    chk "Панель (https://$DOMAIN:$PANEL_PORT)" "✓ работает"
  else
    chk "Панель (порт $PANEL_PORT)" "✗ не отвечает"
  fi
  SUB_PREFIX=""
  if [[ -n "$SUB_SECRET" ]]; then
    SUB_PREFIX="$SUB_SECRET/"
  fi
  SUB_CODE="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    "https://$DOMAIN/$SUB_PREFIX/api/sub/probe" 2>/dev/null || echo 000)"
  if [[ "$SUB_CODE" != "000" ]]; then
    chk "Подписка на 443" "✓ отвечает (HTTP $SUB_CODE)"
  else
    chk "Подписка на 443" "✗ не отвечает"
  fi
  HID_CODE="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    "https://$DOMAIN/api/sub/probe" 2>/dev/null || echo 000)"
  if [[ "$HID_CODE" == "404" ]]; then
    chk "Скрытие /api/sub" "✓ наружу 404 (путь спрятан)"
  else
    chk "Скрытие /api/sub" "✗ /api/sub отвечает $HID_CODE — отпечаток виден"
  fi
  chk "Caddy" "$(systemctl is-active caddy 2>/dev/null || echo 'нет')"
  CERT_PATH="$(ls -1 /var/lib/caddy/.local/share/caddy/certificates/*/"$DOMAIN"/"$DOMAIN".crt 2>/dev/null | head -1 || true)"
  chk "Сертификат Let's Encrypt" "${CERT_PATH:+✓ есть}${CERT_PATH:-✗ нет (Hysteria2 недоступен)}"

  printf '\n── Порты (ufw) ─────────────────────────────\n'
  UFW_OUT="$(ufw status 2>/dev/null || true)"
  if [[ -n "$UFW_OUT" ]]; then printf '%s\n' "$UFW_OUT" | sed 's/^/  /'; else echo "  ufw неактивен"; fi

  printf '\n── API панели ──────────────────────────────\n'
  if [[ -z "$CHK_TOKEN" ]]; then
    chk "API-токен" "✗ нет в $STATE (запустите установку)"
  else
    hdr=(-H "$CLIENT_HDR" -H "Authorization: Bearer $CHK_TOKEN")

    PROF="$(api "$API/config-profiles" "${hdr[@]}" 2>/dev/null | jq -r '.response.configProfiles[0] | "\(.name) / инбаундов: \(.inbounds|length)"' 2>/dev/null || echo '?')"
    chk "Профиль" "$PROF"

    NODE="$(api "$API/nodes" "${hdr[@]}" 2>/dev/null | jq -r '.response[0] | "\(.name): \(if .isConnected then "✓ подключена" else "✗ не подключена" end)"' 2>/dev/null || echo '?')"
    chk "Нода" "$NODE"

    HOSTS="$(api "$API/hosts" "${hdr[@]}" 2>/dev/null | jq -r '.response | length' 2>/dev/null || echo '?')"
    chk "Хостов в подписке" "$HOSTS"

    SQ="$(api "$API/internal-squads" "${hdr[@]}" 2>/dev/null | jq -r '.response.internalSquads[0].name // "нет"' 2>/dev/null || echo '?')"
    chk "Сквад" "$SQ"

    TEST_SUB="$(state_get TEST_SHORT_UUID)"
    if [[ -n "$TEST_SUB" ]]; then
      SUB_RAW="$(curl -sS --max-time 15 -H 'x-forwarded-for: 127.0.0.1' \
        -H 'x-forwarded-proto: https' "$API/sub/$TEST_SUB" 2>/dev/null || true)"
      # Панель для неизвестных ей программ отдаёт подписку в base64.
      SUB_TEXT="$SUB_RAW"
      case "$SUB_RAW" in
        *"://"*) : ;;
        *)
          DECODED="$(printf '%s' "$SUB_RAW" | base64 -d 2>/dev/null || true)"
          case "$DECODED" in *"://"*) SUB_TEXT="$DECODED" ;; esac
          ;;
      esac
      CNT=0
      for proto in vless hysteria2 trojan ss; do
        n=$(printf '%s' "$SUB_TEXT" | awk -v p="$proto" 'index($0, p "://") == 1 {c++} END {print c+0}')
        CNT=$(( CNT + n ))
      done
      chk "Ссылок в подписке" "${CNT:-0}"

      CASCADE_CHK="$(state_get CASCADE_IP)"
      if [[ -n "$CASCADE_CHK" ]]; then
        chk "Каскад" "$CASCADE_CHK"
        if timeout 4 bash -c "cat < /dev/null > /dev/tcp/$CASCADE_CHK/8443" 2>/dev/null; then
          chk "Релей RU→NL (8443)" "✓ проходит через каскад"
        else
          chk "Релей RU→NL (8443)" "✗ не проходит — проверь nsky-relay на русском VPS"
        fi
      fi
      printf '\n  Ссылка подписки:\n    https://%s/%sapi/sub/%s\n' "$DOMAIN" "${SUB_SECRET:+$SUB_SECRET/}" "$TEST_SUB"
    else
      chk "Тестовая подписка" "не создана (запустите установку)"
    fi
  fi

  printf '\n── Последние ошибки ноды ───────────────────\n'
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    docker logs --tail 12 remnanode 2>&1 | sed 's/^/  /'
  else
    echo "  контейнер ноды не создан"
  fi

  printf '\n  Полный лог установки: %s\n\n' "$LOG"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "2/10. Точка восстановления"
# ─────────────────────────────────────────────────────────────────────────────
SNAP_DIR="$DIR/backups"
mkdir -p "$SNAP_DIR"
SNAP="$SNAP_DIR/before-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$SNAP" --absolute-names \
    /etc/ufw /etc/ssh/sshd_config /etc/caddy /etc/docker /etc/hosts \
    2>/dev/null || true
ok "Снимок конфигов: $SNAP"

cat > "$SNAP_DIR/КАК_ОТКАТИТЬ.txt" <<ROLLBACK
Откат установки NSky
════════════════════

САМЫЙ НАДЁЖНЫЙ путь — снапшот диска в панели хостинга.
Сделайте его ДО установки: откат = восстановление снапшота целиком.

Полностью убрать то, что поставил скрипт:

  cd $DIR/panel && docker compose down -v
  cd $DIR/node  && docker compose down
  systemctl stop caddy
  apt-get remove --purge -y caddy
  rm -rf $DIR
  ufw --force reset

Вернуть только конфиги системы:

  tar -xzf $SNAP -C /
  systemctl daemon-reload
  systemctl restart ssh

Переустановить всё с нуля (данные панели будут удалены):

  bash nsky-install.sh $DOMAIN <email> --wipe
ROLLBACK
ok "Инструкция: $SNAP_DIR/КАК_ОТКАТИТЬ.txt"

# ─────────────────────────────────────────────────────────────────────────────
bold "3/10. Система и Docker"
# ─────────────────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg ufw jq openssl tar unzip iproute2 >/dev/null
ok "Базовые пакеты"

# Caddy ставим ЗАРАНЕЕ: его каталог сертификатов монтируется в панель,
# а панель читает оттуда сертификат для Hysteria2.
if ! command -v caddy >/dev/null 2>&1; then
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
  ok "Caddy установлен"
else
  ok "Caddy уже установлен"
fi
mkdir -p /var/lib/caddy/.local/share/caddy

if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
  ok "Docker установлен"
else
  ok "Docker уже установлен"
fi

mkdir -p /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat > /etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "3" }, "live-restore": true }
JSON
fi
systemctl enable --now docker >/dev/null 2>&1
ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"

# ─────────────────────────────────────────────────────────────────────────────
bold "4/10. Firewall"
# ─────────────────────────────────────────────────────────────────────────────
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
for p in "$SSH_PORT/tcp" "80/tcp" "443/tcp" "$REALITY_PORT/tcp" "$XHTTP_PORT/tcp" "$HY2_PORT/udp" "$NODE_PORT/tcp"; do
  ufw allow "$p" >/dev/null
done
# Панель — отдельный порт, доступный только с IP офиса.
# ВАЖНО: никакого общего "ufw deny <порт>". ufw применяет правила сверху
# вниз, первое совпадение выигрывает — deny, добавленный раньше, закрыл бы
# и офис. Закрытость даёт "ufw default deny incoming" выше: кто не попал
# в разрешённые IP, тот не проходит.
if [[ -n "$PANEL_ALLOW_FROM" ]]; then
  _pf=0
  IFS=',' read -ra _PAIPS <<< "$PANEL_ALLOW_FROM"
  for _paip in "${_PAIPS[@]}"; do
    _paip="${_paip//[[:space:]]/}"
    [[ -n "$_paip" ]] || continue
    ufw allow from "$_paip" to any port "$PANEL_PORT" proto tcp >/dev/null 2>&1 && _pf=1
    info "разрешено с $_paip"
  done
  if [[ "$_pf" == "1" ]]; then
    ok "панель $PANEL_PORT/tcp — только с IP офиса ($PANEL_ALLOW_FROM)"
  else
    warn "не удалось разрешить $PANEL_PORT/tcp для $PANEL_ALLOW_FROM"
  fi
else
  warn "PANEL_ALLOW_FROM не задан — панель открыта для всех IP (задайте --panel-ip <IP/CIDR>)"
  ufw allow "$PANEL_PORT/tcp" >/dev/null
fi
ufw --force enable >/dev/null
ok "Открыты: $SSH_PORT(ssh), 80, 443/tcp (подписка), $REALITY_PORT/tcp (REALITY), $XHTTP_PORT/tcp (XHTTP), $HY2_PORT/udp (Hysteria2), $NODE_PORT/tcp (нода), $PANEL_PORT/tcp (панель)"

# ─────────────────────────────────────────────────────────────────────────────
bold "5/10. Подготовка к установке"
# ─────────────────────────────────────────────────────────────────────────────
# Старые контейнеры имеют те же имена (remnawave, remnawave-db, ...).
OLD_CONTAINERS=(remnawave remnawave-db remnawave-redis remnanode)

# Контейнеры убираем по именам и без условий: docker не даст создать новые
# поверх существующих, а проверить, к какому проекту они относились, нельзя.
# Это безопасно — данные лежат в томах, а не в контейнерах.
for p in "$PROJECT" "$PROJECT_NODE" remnawave panel; do
  docker compose -p "$p" -f "$DIR/panel/docker-compose.yml" down >/dev/null 2>&1 || true
  docker compose -p "$p" -f "$DIR/node/docker-compose.yml"   down >/dev/null 2>&1 || true
done
for c in "${OLD_CONTAINERS[@]}"; do
  docker rm -f "$c" >/dev/null 2>&1 || true
done
ok "Старые контейнеры убраны"

# Сеть и том с unix-сокетом принадлежали прошлым запускам (проект panel и т.п.).
# Их метки не совпадают с текущим проектом, и docker ругается при старте.
# Данных в них нет: сеть создаётся заново, сокет пишет сам valkey.
docker network rm nsky >/dev/null 2>&1 || true
docker volume rm valkey-socket >/dev/null 2>&1 || true

if [[ "$MODE" == "wipe" ]]; then
  info "Режим --wipe: удаляю данные прошлой установки (база панели, ключи)…"
  for v in remnawave-db-data panel_db-data nsky_db-data db-data \
           "${PROJECT}_db-data" "${PROJECT}_valkey-socket" panel_valkey-socket nsky_valkey-socket; do
    docker volume rm -f "$v" >/dev/null 2>&1 || true
  done
  rm -rf "$DIR/panel" "$DIR/node"
  # Пароли прошлой установки больше не действуют — начинаем с чистого листа.
  if [[ -f "$STATE" ]]; then
    cp "$STATE" "$DIR/backups/install-state.before-wipe-$(date +%Y%m%d-%H%M%S).env" 2>/dev/null || true
    rm -f "$STATE"
  fi
  ok "Данные удалены. Логи и бэкапы сохранены в $DIR"
else
  info "Данные прошлой установки сохраняются (для полного сноса добавьте --wipe)"
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "6/10. Панель Remnawave"
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$DIR/panel" "$DIR/node"

if [[ ! -f "$STATE" ]]; then
  cat > "$STATE" <<ENV
SERVER_IP=$SERVER_IP
DOMAIN=$DOMAIN
DB_PASS=$(rnd 16)
APP_SECRET=$(rnd 32)
METRICS_PASS=$(rnd 12)
ADMIN_USER=admin
ADMIN_PASS=$(gen_password)
ENV
  chmod 600 "$STATE"
  ok "Новые пароли созданы"
else
  ok "Использую пароли из прошлой установки"
fi
# shellcheck disable=SC1090
source "$STATE"
[[ -n "${ADMIN_PASS:-}" ]] || { ADMIN_PASS="$(gen_password)"; state_set ADMIN_PASS "$ADMIN_PASS"; }

# Секрет в URL подписки: создаётся один раз и ВСЕГДА пишется в state.
# state_set обязателен даже для подхваченного значения: state удаляется
# при --wipe позже создания нового, и без этой записи секрет бы терялся —
# следующий запуск сгенерировал бы новый и сломал разосланные ссылки.
if [[ -z "$SUB_SECRET" ]]; then
  SUB_SECRET="$(rnd 6)"
fi
[[ -n "$SUB_SECRET" ]] || SUB_SECRET="sub"
state_set SUB_SECRET "$SUB_SECRET"
SUB_PUBLIC_DOMAIN="${DOMAIN}/${SUB_SECRET}/api/sub"

cat > "$DIR/panel/.env" <<ENV
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
SUB_PUBLIC_DOMAIN=${SUB_PUBLIC_DOMAIN}
METRICS_USER=nsky
METRICS_PASS=${METRICS_PASS}
WEBHOOK_ENABLED=false
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=false
NOT_CONNECTED_USERS_NOTIFICATIONS_ENABLED=false
EXPIRATION_NOTIFICATIONS_ENABLED=false
EXPORT_TO_STREAM_ENABLED=false
SERVICE_SNI_VERIFICATION=true
SHORT_UUID_METHOD=uuid
COMPOSE_PROJECT_NAME=${PROJECT}
ENV
chmod 600 "$DIR/panel/.env"

# Имена томов заданы явно, чтобы --wipe и повторный запуск не плодили копии.
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
    volumes:
      - valkey-socket:/var/run/valkey
      # Сертификат для Hysteria2: панель читает файл и вставляет PEM в конфиг.
      - /var/lib/caddy/.local/share/caddy:/caddy-data:ro
    ports: ['127.0.0.1:3000:3000', '127.0.0.1:3001:3001']
    healthcheck:
      test: ['CMD-SHELL', 'curl -fsS http://localhost:3001/health || exit 1']
      interval: 20s
      timeout: 5s
      retries: 5
      start_period: 120s
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
    volumes: ['remnawave-db-data:/var/lib/postgresql']
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}']
      interval: 5s
      timeout: 5s
      retries: 12

  remnawave-redis:
    image: valkey/valkey:9-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    <<: [*common, *logging]
    volumes: ['valkey-socket:/var/run/valkey']
    command: >
      valkey-server --save "" --appendonly no --maxmemory-policy noeviction
      --unixsocket /var/run/valkey/valkey.sock --unixsocketperm 777 --port 0
    healthcheck:
      test: ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping']
      interval: 5s
      timeout: 3s
      retries: 12

volumes:
  remnawave-db-data: { name: remnawave-db-data }
  valkey-socket: { name: valkey-socket }
networks:
  nsky: { name: nsky }
COMPOSE

cd "$DIR/panel"
info "Скачиваю образы (может занять несколько минут)…"
docker compose pull -q 2>/dev/null || docker compose pull
info "Запускаю. Панель сама применит миграции БД и создаст профиль по умолчанию…"
docker compose up -d

printf '    жду готовности панели'
READY=0
for _ in $(seq 1 100); do
  if curl -fsS --max-time 2 -H 'x-forwarded-proto: https' http://127.0.0.1:3001/health >/dev/null 2>&1; then READY=1; break; fi
  printf '.'; sleep 3
done
printf '\n'
if [[ "$READY" != "1" ]]; then
  docker logs --tail 60 remnawave || true
  die "Панель не поднялась. Смотрите: docker logs remnawave"
fi
ok "Панель отвечает на 127.0.0.1:3000"

# ─────────────────────────────────────────────────────────────────────────────
bold "7/10. HTTPS (Caddy)"
# ─────────────────────────────────────────────────────────────────────────────
cat > /etc/caddy/Caddyfile <<CADDY
{
    email $EMAIL

    # HTTP/3 (QUIC) занимает UDP 443, а он нужен Hysteria2. Проверено в
    # исходниках Caddy: defaultProtocols = {"h1","h2","h3"} (server.go).
    # Без этой строки Xray падает с 'listen udp 0.0.0.0:443: address already in use'.
    servers {
        protocols h1 h2
    }
}

# Панель управления — отдельный порт. ufw ниже не допускает посторонние
# IP, поэтому они вообще не дойдут до Caddy.
$DOMAIN:$PANEL_PORT {
    reverse_proxy 127.0.0.1:3000 {
        header_up X-Real-IP {remote_host}
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        -Server
    }
    encode gzip zstd
}

# Публичная подписка — на 443, но спрятана под секретный сегмент URL.
# Путь /api/sub известен сканерам как отпечаток Remnawave, поэтому наружу
# он отдаёт 404 самим Caddy (панель не участвует, отпечатков нет).
# Панель одобряет подписку только по секретному пути; клиенты просто
# получают готовую ссылку, для них это обычный URL.
$DOMAIN {
    handle /$SUB_SECRET/api/sub* {
        uri strip_prefix /$SUB_SECRET
        reverse_proxy 127.0.0.1:3000 {
            header_up X-Real-IP {remote_host}
        }
    }
    header {
        -Server
    }
    respond "Not Found" 404
}
CADDY
# Проверяем конфиг до перезапуска: ошибка в Caddyfile уронила бы HTTPS.
if ! caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
  warn "Caddyfile не прошёл проверку:"
  caddy validate --config /etc/caddy/Caddyfile 2>&1 | tail -5 || true
  die "Исправьте /etc/caddy/Caddyfile"
fi
ok "Caddyfile проверен"

systemctl enable caddy >/dev/null 2>&1
systemctl restart caddy
sleep 6

HTTPS_OK=0
if [[ "$DNS_OK" == "1" ]] && curl -fsS --max-time 15 "https://$DOMAIN:$PANEL_PORT" >/dev/null 2>&1; then
  HTTPS_OK=1; ok "Панель отвечает: https://$DOMAIN:$PANEL_PORT"
else
  warn "HTTPS пока не отвечает. Причины: DNS не совпал или порт 80 закрыт у хостера."
  warn "Сертификат выпустится сам, как только условия выполнятся."
fi

# Ждём файл сертификата: он нужен Hysteria2 (Xray без TLS этот инбаунд не примет).
printf "    жду сертификат от Let's Encrypt"
CERT_FILE=""
for _ in $(seq 1 30); do
  CERT_FILE="$(ls -1 /var/lib/caddy/.local/share/caddy/certificates/*/"$DOMAIN"/"$DOMAIN".crt 2>/dev/null | head -1 || true)"
  if [[ -n "$CERT_FILE" ]]; then break; fi
  printf '.'; sleep 4
done
printf '\n'
if [[ -n "$CERT_FILE" ]]; then
  ok "Сертификат выпущен: $CERT_FILE"
else
  warn "Сертификат не появился за 2 минуты"
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "8/10. Администратор и токен"
# ─────────────────────────────────────────────────────────────────────────────
json_field() { jq -r "$1 // empty" 2>/dev/null || true; }

# Вход с известным паролем.
# Важно: результат кладём в переменные оболочки, а не печатаем в stdout —
# вызывать через $(...) нельзя, иначе LAST_CODE/LAST_MSG окажутся
# в подоболочке и снаружи будут пустыми.
LOGIN_TOKEN=""
LAST_CODE=""
LAST_MSG=""
login_token() {
  local pass="$1" user="${2:-$ADMIN_USER}" body out code resp
  LOGIN_TOKEN=""
  LAST_CODE=""
  LAST_MSG=""
  body=$(jq -n --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')
  out=$(api -X POST "$API/auth/login" -H "$CLIENT_HDR" \
    -H 'Content-Type: application/json' -d "$body" -w '\n%{http_code}' 2>/dev/null || printf '\n000')
  code=$(printf '%s' "$out" | tail -1)
  resp=$(printf '%s' "$out" | sed '$d')
  LOGIN_TOKEN=$(printf '%s' "$resp" | json_field '.response.accessToken')
  LAST_CODE="${code:-000}"
  LAST_MSG="$(printf '%s' "$resp" | json_field '.message')"
  if [[ -z "$LAST_MSG" ]]; then
    LAST_MSG="$(printf '%s' "$resp" | tr -d '\n' | head -c 160)"
  fi
  LAST_MSG="${LAST_MSG:-пустой ответ}"
}

info "Проверяю доступ: какие способы входа разрешены…"
ST_RESP=$(api "$API/auth/status" -H "$CLIENT_HDR" 2>/dev/null || echo '{}')
LOGIN_ALLOWED=$(printf '%s' "$ST_RESP" | jq -r '.response.isLoginAllowed // "нет ответа"' 2>/dev/null || echo "нет ответа")
REG_ALLOWED=$(printf '%s' "$ST_RESP" | jq -r '.response.isRegisterAllowed // "нет ответа"' 2>/dev/null || echo "нет ответа")
info "вход разрешён: $LOGIN_ALLOWED, регистрация разрешена: $REG_ALLOWED"

login_token "$ADMIN_PASS"
JWT="$LOGIN_TOKEN"
if [[ -n "$JWT" ]]; then
  ok "Вход выполнен (пароль из $STATE)"
else
  info "Вход с паролем из прошлой установки не прошёл (HTTP ${LAST_CODE:-?}): ${LAST_MSG:-без ответа}"

  # Панель чистая — создаём первого администратора.
  body=$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{username:$u,password:$p}')
  out=$(api -X POST "$API/auth/register" -H "$CLIENT_HDR" \
    -H 'Content-Type: application/json' -d "$body" -w '\n%{http_code}' 2>/dev/null || printf '\n000')
  REG_CODE=$(printf '%s' "$out" | tail -1)
  REG_RESP=$(printf '%s' "$out" | sed '$d')
  JWT=$(printf '%s' "$REG_RESP" | json_field '.response.accessToken')

  if [[ -n "$JWT" ]]; then
    ok "Администратор создан: $ADMIN_USER"
  else
    info "Регистрация не прошла (HTTP ${REG_CODE}): $(printf '%s' "$REG_RESP" | json_field '.message')"

    if [[ "$REG_CODE" == "000" ]]; then
      warn "Панель не отвечает на локальный запрос — смотрите: docker logs --tail 30 remnawave"
    elif [[ "$LOGIN_ALLOWED" == "true" ]]; then
      info "В панели уже есть администратор с другим логином или паролем."
      info "Введите логин и пароль действующего админа. Пустой ввод — шаги 9-10 будут пропущены."
      read -rp '    Логин админа ['$ADMIN_USER']: ' INPUT_USER || true
      INPUT_USER="${INPUT_USER:-$ADMIN_USER}"
      read -rsp '    Пароль: ' INPUT_PASS || true
      echo
      if [[ -n "${INPUT_PASS:-}" ]]; then
        login_token "$INPUT_PASS" "$INPUT_USER"
        JWT="$LOGIN_TOKEN"
        if [[ -n "$JWT" ]]; then
          ADMIN_USER="$INPUT_USER"
          ADMIN_PASS="$INPUT_PASS"
          state_set ADMIN_USER "$ADMIN_USER"
          state_set ADMIN_PASS "$ADMIN_PASS"
          ok "Вход выполнен под $ADMIN_USER (сохранено в $STATE)"
        else
          warn "Не подошло (HTTP ${LAST_CODE:-?}): ${LAST_MSG:-без ответа}"
        fi
      fi
    fi
  fi
fi

if [[ -z "$JWT" ]]; then
  echo
  bad "Нет доступа к панели — дальше идти нельзя."
  echo
  echo "  Что можно сделать:"
  echo "    1) Узнать пароль админа нельзя, но можно создать панель заново:"
  echo "         bash $0 $DOMAIN $EMAIL --wipe"
  echo "       Это удалит базу панели (пользователей пока нет) и задаст новый пароль."
  echo "    2) Если в панели есть нужные данные — не запускайте --wipe,"
  echo "       а войдите паролем вручную на https://$DOMAIN:$PANEL_PORT и запустите скрипт снова."
  echo
  die "Установка остановлена на шаге 8"
fi

# Долгоживущий токен для последующих запусков и для админки.
API_TOKEN="$(state_get API_TOKEN)"
if [[ -z "$API_TOKEN" ]]; then
  resp=$(api -X POST "$API/tokens" -H "$CLIENT_HDR" -H "Authorization: Bearer $JWT" \
    -H 'Content-Type: application/json' \
    -d '{"name":"nsky-installer","expiresInDays":3650,"scopes":["*"]}' 2>/dev/null || echo '{}')
  API_TOKEN=$(printf '%s' "$resp" | json_field '.response.token')
  if [[ -n "$API_TOKEN" ]]; then
    state_set API_TOKEN "$API_TOKEN"
    ok "API-токен создан и сохранён ($STATE)"
  else
    warn "API-токен не создан: $(printf '%s' "$resp" | json_field '.message')"
  fi
else
  ok "API-токен уже есть"
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "9/10. Профиль Xray, хосты, нода"
# ─────────────────────────────────────────────────────────────────────────────
auth_hdr=(-H "$CLIENT_HDR" -H "Authorization: Bearer $JWT")

# 9.1 Ключи REALITY
info "Генерирую ключи REALITY (xray x25519 в образе ноды)…"
docker pull -q "remnawave/node:3.4.4" >/dev/null 2>&1 || true
X25519_OUT="$(docker run --rm --entrypoint /usr/local/bin/xray remnawave/node:3.4.4 x25519 2>&1 || true)"
REALITY_PRIV="$(printf '%s' "$X25519_OUT" | sed -n 's/^PrivateKey: //p' | tr -d ' \r' | head -1)"
REALITY_PUB="$(printf '%s' "$X25519_OUT" | sed -n 's/^Password (PublicKey): //p' | tr -d ' \r' | head -1)"
if [[ -z "$REALITY_PRIV" || -z "$REALITY_PUB" ]]; then
  warn "x25519 не сработал, первые строки вывода:"
  printf '%s\n' "$X25519_OUT" | head -3
  die "Без пары ключей REALITY туннель не заработает. Проверьте доступ к docker pull."
fi
ok "Ключи готовы (pub: ${REALITY_PUB:0:10}…)"

REALITY_SHORT_ID="$(rnd 8)"
XHTTP_PATH="/$(rnd 4)$(rnd 4)"

# 9.1.1 Сертификат для Hysteria2.
# Xray требует для hysteria настоящий TLS (tls config is nil → инбаунд не стартует).
# Caddy уже выпустил Let's Encrypt — берём его файлы через read-only монтирование.
TLS_CERT=""
TLS_KEY=""
# Путь внутри контейнера панели (каталог caddy смонтирован в /caddy-data).
if [[ -n "$CERT_FILE" ]]; then
  TLS_CERT="/caddy-data/certificates/$(basename "$(dirname "$(dirname "$CERT_FILE")")")/$DOMAIN/$DOMAIN.crt"
  TLS_KEY="${TLS_CERT%.crt}.key"
fi

if [[ -n "$TLS_CERT" ]]; then
  ok "Сертификат для Hysteria2 найден (путь в панели: $TLS_CERT)"
else
  warn "Сертификата Caddy пока нет — Hysteria2 будет добавлен при повторном запуске"
  warn "VLESS+REALITY и VLESS+XHTTP работают без него"
fi
state_set REALITY_PRIV "$REALITY_PRIV"
state_set REALITY_PUB "$REALITY_PUB"
state_set REALITY_SNI "$REALITY_SNI"
state_set REALITY_SHORT_ID "$REALITY_SHORT_ID"
state_set XHTTP_PATH "$XHTTP_PATH"
state_set PANEL_PORT "$PANEL_PORT"
state_set PANEL_ALLOW_FROM "$PANEL_ALLOW_FROM"

# 9.2 Профиль: панель создаёт Default-Profile сидером, поэтому ищем и обновляем,
#     а не создаём (POST вернёт 400).
# Базовые два инбаунда есть всегда. Hysteria2 добавляется ТОЛЬКО когда есть
# настоящий сертификат: без TLS Xray не поднимет инбаунд и уронит всю ноду.
JQ_COMMON=(
  --arg tagr "vless-reality-$REALITY_PORT"
  --arg tagx "vless-xhttp-$XHTTP_PORT"
  --arg sni "$REALITY_SNI"
  --arg priv "$REALITY_PRIV"
  --arg sid "$REALITY_SHORT_ID"
  --arg xpath "$XHTTP_PATH"
  --argjson rport "$REALITY_PORT"
  --argjson xport "$XHTTP_PORT"
)

INB_REALITY_CFG='{
  tag: $tagr, listen: "0.0.0.0", port: $rport, protocol: "vless",
  settings: { clients: [], decryption: "none" },
  streamSettings: {
    network: "raw", security: "reality",
    realitySettings: {
      show: false, target: ($sni + ":443"), xver: 0,
      serverNames: [$sni], privateKey: $priv, shortIds: [$sid]
    }
  },
  sniffing: { enabled: true, destOverride: ["http","tls","quic"], routeOnly: true }
}'

INB_XHTTP_CFG='{
  tag: $tagx, listen: "0.0.0.0", port: $xport, protocol: "vless",
  settings: { clients: [], decryption: "none" },
  streamSettings: {
    network: "xhttp", security: "reality",
    realitySettings: {
      show: false, target: ($sni + ":443"), xver: 0,
      serverNames: [$sni], privateKey: $priv, shortIds: [$sid]
    },
    xhttpSettings: { path: $xpath, mode: "auto" }
  },
  sniffing: { enabled: true, destOverride: ["http","tls","quic"], routeOnly: true }
}'

INB_HY2_CFG='{
  tag: $tagh, listen: "0.0.0.0", port: $hport, protocol: "hysteria",
  settings: { version: 2, users: [] },
  streamSettings: {
    network: "hysteria", security: "tls",
    tlsSettings: {
      alpn: ["h3"],
      certificates: [{ certificateFile: $cert, keyFile: $key }]
    },
    hysteriaSettings: { version: 2, udpIdleTimeout: 60 }
  },
  sniffing: { enabled: true, destOverride: ["http","tls","quic"], routeOnly: true }
}'

OUTBOUNDS='[
  { protocol: "freedom", tag: "DIRECT" },
  { protocol: "blackhole", tag: "BLOCK" }
]'

ROUTING='{
  domainStrategy: "IPIfNonMatch",
  rules: [
    { protocol: ["bittorrent"], outboundTag: "BLOCK" },
    { ip: ["geoip:private"], outboundTag: "DIRECT" }
  ]
}'

if [[ -n "$TLS_CERT" ]]; then
  PROFILE_JSON=$(jq -n "${JQ_COMMON[@]}" \
    --arg tagh "hysteria2-$HY2_PORT-udp" --argjson hport "$HY2_PORT" \
    --arg cert "$TLS_CERT" --arg key "$TLS_KEY" \
    "{
       log: { loglevel: \"warning\" },
       inbounds: [ $INB_REALITY_CFG, $INB_XHTTP_CFG, $INB_HY2_CFG ],
       outbounds: $OUTBOUNDS,
       routing: $ROUTING
     }")
  PROTO_SUMMARY="REALITY :$REALITY_PORT/tcp, XHTTP :$XHTTP_PORT/tcp, Hysteria2 :$HY2_PORT/udp"
else
  PROFILE_JSON=$(jq -n "${JQ_COMMON[@]}" \
    "{
       log: { loglevel: \"warning\" },
       inbounds: [ $INB_REALITY_CFG, $INB_XHTTP_CFG ],
       outbounds: $OUTBOUNDS,
       routing: $ROUTING
     }")
  PROTO_SUMMARY="REALITY :$REALITY_PORT/tcp, XHTTP :$XHTTP_PORT/tcp"
fi

# Локальная проверка JSON до отправки в панель.
if ! printf '%s' "$PROFILE_JSON" | jq -e '.inbounds | length >= 2' >/dev/null 2>&1; then
  printf '%s\n' "$PROFILE_JSON" | head -c 500; echo
  die "Сгенерированный конфиг профиля некорректен"
fi
info "Протоколы в профиле: $PROTO_SUMMARY"

# 9.2 Профиль: панель создаёт Default-Profile сидером, поэтому ищем и обновляем,
#     а не создаём (POST вернёт 400, если профиль уже есть).
resp=$(api "${auth_hdr[@]}" "$API/config-profiles")
PROFILES="$(printf '%s' "$resp")"
PROFILE_UUID="$(printf '%s' "$PROFILES" | jq -r '.response.configProfiles[0].uuid // empty' 2>/dev/null || true)"
PROFILE_NAME="$(printf '%s' "$PROFILES" | jq -r '.response.configProfiles[0].name // "nsky-main"' 2>/dev/null || echo "nsky-main")"

if [[ -z "$PROFILE_UUID" ]]; then
  info "Готовых профилей нет — создаю новый"
  body=$(jq -n --argjson cfg "$PROFILE_JSON" '{name:"nsky-main",config:$cfg}')
  resp=$(api -X POST "$API/config-profiles" "${auth_hdr[@]}" \
    -H 'Content-Type: application/json' -d "$body")
  PROFILE_UUID=$(printf '%s' "$resp" | json_field '.response.uuid')
  if [[ -z "$PROFILE_UUID" ]]; then
    printf '%s\n' "$resp" | head -c 700; echo
    die "Профиль не создан"
  fi
  PROFILE_NAME="nsky-main"
  ok "Профиль создан: $PROFILE_NAME"
else
  body=$(jq -n --arg u "$PROFILE_UUID" --arg n "$PROFILE_NAME" --argjson cfg "$PROFILE_JSON" \
    '{uuid:$u,name:$n,config:$cfg}')
  resp=$(api -X PATCH "$API/config-profiles" "${auth_hdr[@]}" \
    -H 'Content-Type: application/json' -d "$body")
  if [[ "$(printf '%s' "$resp" | jq -r '.response.uuid // empty' 2>/dev/null)" == "$PROFILE_UUID" ]]; then
    ok "Профиль обновлён: $PROFILE_NAME"
  else
    printf '%s\n' "$resp" | head -c 900; echo
    die "Профиль не обновился"
  fi
fi
state_set PROFILE_UUID "$PROFILE_UUID"

# 9.3 UUID инбаундов (нужны для ноды, хостов и сквада)
resp=$(api "${auth_hdr[@]}" "$API/config-profiles/$PROFILE_UUID/inbounds")
INB_JSON="$(printf '%s' "$resp" | jq -c '[.response.inbounds[]? | {u:.uuid,t:.tag,n:.network,p:.port}]' 2>/dev/null || echo '[]')"
[[ "$INB_JSON" != "[]" ]] || { printf '%s\n' "$resp" | head -c 500; echo; die "Не удалось получить инбаунды профиля"; }

inb_uuid() { printf '%s' "$INB_JSON" | jq -r --arg t "$1" '[.[] | select(.t==$t)][0].u // empty'; }
INB_REALITY="$(inb_uuid "vless-reality-$REALITY_PORT")"
INB_XHTTP="$(inb_uuid "vless-xhttp-$XHTTP_PORT")"
INB_HY2="$(inb_uuid "hysteria2-$HY2_PORT-udp")"
[[ -n "$INB_REALITY" && -n "$INB_XHTTP" ]] \
  || die "Панель не сохранила базовые инбаунды (reality=$INB_REALITY xhttp=$INB_XHTTP)"

# Список инбаундов для ноды собираем только из существующих.
INB_LIST_ALL=("$INB_REALITY" "$INB_XHTTP")
if [[ -n "$INB_HY2" ]]; then INB_LIST_ALL+=("$INB_HY2"); fi
INB_ALL="$(printf '%s\n' "${INB_LIST_ALL[@]}" | jq -R . | jq -sc .)"
ok "Инбаунды: REALITY :$REALITY_PORT, XHTTP :$XHTTP_PORT$([[ -n "$INB_HY2" ]] && echo ", Hysteria2 :$HY2_PORT/udp")"

# 9.4 Сквад — выдаёт пользователям доступ к нодам. Без него подписка пустая.
resp=$(api "${auth_hdr[@]}" "$API/internal-squads")
SQUAD_UUID="$(printf '%s' "$resp" | jq -r '.response.internalSquads[0].uuid // empty' 2>/dev/null || true)"
if [[ -z "$SQUAD_UUID" ]]; then
  body=$(jq -n --argjson inb "$INB_ALL" '{name:"NSky",inbounds:$inb}')
  resp=$(api -X POST "$API/internal-squads" "${auth_hdr[@]}" \
    -H 'Content-Type: application/json' -d "$body")
  SQUAD_UUID=$(printf '%s' "$resp" | json_field '.response.uuid')
  if [[ -n "$SQUAD_UUID" ]]; then ok "Сквад создан: NSky"; fi
else
  body=$(jq -n --arg u "$SQUAD_UUID" --argjson inb "$INB_ALL" '{uuid:$u,inbounds:$inb}')
  api -X PATCH "$API/internal-squads" "${auth_hdr[@]}" \
    -H 'Content-Type: application/json' -d "$body" >/dev/null
  ok "Сквад обновлён"
fi
[[ -n "$SQUAD_UUID" ]] || die "Не удалось создать внутренний сквад"
state_set SQUAD_UUID "$SQUAD_UUID"

# 9.5 Хосты — то, что реально попадает в подписку.
#     Без них клиент получает "No hosts found".
HOSTS_FAILED=0
ensure_host() {
  local remark="$1" inb="$2" port="$3" sni="$4" alpn="$5" addr="${6:-$SERVER_IP}" resp uuid
  resp=$(api "${auth_hdr[@]}" "$API/hosts")
  uuid=$(printf '%s' "$resp" | jq -r --arg r "$remark" \
    '[.response[]? | select(.remark==$r)][0].uuid // empty' 2>/dev/null || true)

  # Пустые sni/alpn передавать нельзя: alpn проверяется как z.enum(ALPN),
  # и пустая строка даёт "Validation failed". Добавляем только заполненные.
  # if, а не "[[ ]] &&": при set -e ложное условие в конце блока обрывает скрипт.
  local jq_extra=()
  local filter='.'
  if [[ -n "$sni" ]]; then
    jq_extra+=(--arg s "$sni")
    filter="$filter + {sni:\$s}"
  fi
  if [[ -n "$alpn" ]]; then
    jq_extra+=(--arg al "$alpn")
    filter="$filter + {alpn:\$al}"
  fi

  local body
  body=$(jq -n --arg r "$remark" --arg pu "$PROFILE_UUID" --arg iu "$inb" \
    --arg a "$addr" --argjson p "$port" "${jq_extra[@]}" \
    "{inbound:{configProfileUuid:\$pu,configProfileInboundUuid:\$iu},
      remark:\$r, address:\$a, port:\$p, isDisabled:false} | $filter")

  if [[ -n "$uuid" ]]; then
    body=$(printf '%s' "$body" | jq --arg u "$uuid" '. + {uuid:$u}')
    resp=$(api -X PATCH "$API/hosts" "${auth_hdr[@]}" -H 'Content-Type: application/json' -d "$body")
    if [[ -n "$(printf '%s' "$resp" | json_field '.response.uuid')" ]]; then
      ok "Хост обновлён: $remark"
      return 0
    fi
    # Старый хост мог остаться с несовместимыми полями — пересоздаём его.
    warn "Хост '$remark' не обновился ($(printf '%s' "$resp" | json_field '.message')). Пересоздаю."
    api -X DELETE "$API/hosts/$uuid" "${auth_hdr[@]}" >/dev/null 2>&1 || true
  fi

  resp=$(api -X POST "$API/hosts" "${auth_hdr[@]}" -H 'Content-Type: application/json' -d "$body")
  if [[ -n "$(printf '%s' "$resp" | json_field '.response.uuid')" ]]; then
    ok "Хост создан: $remark"
  else
    warn "Хост '$remark' не создан: $(printf '%s' "$resp" | json_field '.message')"
    HOSTS_FAILED=1
  fi
}

ensure_host "NSky REALITY"   "$INB_REALITY" "$REALITY_PORT" "$REALITY_SNI" ""
ensure_host "NSky XHTTP"     "$INB_XHTTP"   "$XHTTP_PORT"   "$REALITY_SNI" ""
if [[ -n "$TLS_CERT" && -n "$INB_HY2" ]]; then
  ensure_host "NSky Hysteria2" "$INB_HY2" "$HY2_PORT" "$DOMAIN" ""
fi
if [[ "$HOSTS_FAILED" == "1" ]]; then
  warn "Часть хостов не создалась — подписка будет неполной."
  warn "Проверьте вручную: панель → Hosts. Подробности в $LOG"
fi
info "Hysteria2 работает по UDP."

# 9.5b Каскад: дубли хостов с адресом русского релея.
# Сквад ссылается только на инбаунды, поэтому хосты с теми же инбаундами
# попадают в ту же подписку автоматически — сотрудники увидят серверы (RU).
if [[ "$CASCADE_REMOVE" == "1" ]]; then
  resp=$(api "${auth_hdr[@]}" "$API/hosts")
  REMOVED=0
  for u in $(printf '%s' "$resp" | jq -r '.response[]? | select((.remark|endswith(" (RU)"))) | .uuid' 2>/dev/null || true); do
    api -X DELETE "$API/hosts/$u" "${auth_hdr[@]}" >/dev/null 2>&1 || true
    REMOVED=$(( REMOVED + 1 ))
  done
  CASCADE_IP=""
  state_set CASCADE_IP ""
  ok "Каскад выключен, хостов удалено: $REMOVED"
elif [[ -n "$CASCADE_IP" ]]; then
  [[ "$CASCADE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || die "--cascade: не похоже на IPv4: $CASCADE_IP"
  HOSTS_FAILED=0
  ensure_host "NSky REALITY (RU)"   "$INB_REALITY" "$REALITY_PORT" "$REALITY_SNI" "" "$CASCADE_IP"
  ensure_host "NSky XHTTP (RU)"     "$INB_XHTTP"   "$XHTTP_PORT"   "$REALITY_SNI" "" "$CASCADE_IP"
  if [[ -n "$TLS_CERT" && -n "$INB_HY2" ]]; then
    ensure_host "NSky Hysteria2 (RU)" "$INB_HY2"   "$HY2_PORT"     "$DOMAIN"      "" "$CASCADE_IP"
  fi
  if [[ "$HOSTS_FAILED" == "1" ]]; then
    warn "Часть каскадных хостов не создалась. Подробности в $LOG"
  else
    state_set CASCADE_IP "$CASCADE_IP"
    ok "Каскад активен: серверы (RU) идут через $CASCADE_IP"
  fi
fi

# 9.6 Нода
resp=$(api "${auth_hdr[@]}" "$API/nodes")
NODE_UUID="$(printf '%s' "$resp" | jq -r '.response[0].uuid // empty' 2>/dev/null || true)"

if [[ -n "$NODE_UUID" ]]; then
  body=$(jq -n --arg u "$NODE_UUID" --arg pu "$PROFILE_UUID" --argjson inb "$INB_ALL" \
    '{uuid:$u, configProfile:{activeConfigProfileUuid:$pu, activeInbounds:$inb}}')
  api -X PATCH "$API/nodes" "${auth_hdr[@]}" -H 'Content-Type: application/json' \
    -d "$body" >/dev/null
  ok "Нода уже есть, профиль привязан заново"
else
  body=$(jq -n --arg a "$SERVER_IP" --arg pu "$PROFILE_UUID" --argjson inb "$INB_ALL" \
    '{name:"nsky-node-1", address:$a, port:2222, countryCode:"NL",
      isTrafficTrackingActive:false,
      configProfile:{activeConfigProfileUuid:$pu, activeInbounds:$inb}}')
  resp=$(api -X POST "$API/nodes" "${auth_hdr[@]}" -H 'Content-Type: application/json' -d "$body")
  NODE_UUID=$(printf '%s' "$resp" | json_field '.response.uuid')
  [[ -n "$NODE_UUID" ]] || { printf '%s\n' "$resp" | head -c 700; echo; die "Нода не создана"; }
  ok "Нода создана: nsky-node-1"
fi
state_set NODE_UUID "$NODE_UUID"

# 9.7 Ключ ноды и запуск контейнера
resp=$(api "${auth_hdr[@]}" "$API/keygen")
NODE_SECRET="$(printf '%s' "$resp" | json_field '.response.secretKey')"
[[ -n "$NODE_SECRET" ]] || die "Секрет ноды не получен: $(printf '%s' "$resp" | json_field '.message')"
state_set NODE_SECRET "$NODE_SECRET"
ok "Секрет ноды получен"

# Перед запуском ноды проверяем, что её порты свободны. Иначе Xray упадёт
# с 'address already in use', а скрипт покажет это только через 2 минуты.
udp443_holder() {
  # ss есть в iproute2 (стоит по умолчанию), но на случай отсутствия — lsof.
  if command -v ss >/dev/null 2>&1; then
    ss -lunp 2>/dev/null | awk 'NR>1 && /:443 / {print $NF}' | head -1
  elif command -v lsof >/dev/null 2>&1; then
    lsof -i udp:443 -sUDP:LISTEN 2>/dev/null | awk 'NR>1 {print $1; exit}'
  fi
}
UDP_HOLDER="$(udp443_holder || true)"
if [[ -n "$UDP_HOLDER" ]]; then
  warn "UDP 443 уже занят: $UDP_HOLDER"
  if printf '%s' "$UDP_HOLDER" | grep -qi caddy; then
    info "Это Caddy с HTTP/3 — перезапускаю его без h3 (см. Caddyfile)"
    systemctl restart caddy
    sleep 4
  fi
  UDP_HOLDER="$(udp443_holder || true)"
  if [[ -n "$UDP_HOLDER" ]]; then
    die "UDP 443 всё ещё занят: $UDP_HOLDER. Освободите порт, иначе Hysteria2 не запустится."
  fi
fi
ok "UDP 443 свободен для Hysteria2"

cat > "$DIR/node/.env" <<ENV
NODE_PORT=${NODE_PORT}
SECRET_KEY=${NODE_SECRET}
COMPOSE_PROJECT_NAME=${PROJECT_NODE}
ENV
chmod 600 "$DIR/node/.env"

# Сертификат монтируем и в ноду тоже: Xray читает ФАЙЛ из конфига (панель
# лишь вставляет путь), поэтому внутри контейнера ноды путь должен существовать.
# Без этого Xray падает с 'failed to parse certificate ... no such file'.
cat > "$DIR/node/docker-compose.yml" <<COMPOSE
services:
  remnanode:
    image: remnawave/node:3.4.4
    container_name: remnanode
    hostname: remnanode
    network_mode: host
    restart: always
    env_file: .env
    cap_add: [NET_ADMIN]
    ulimits: { nofile: { soft: 1048576, hard: 1048576 } }
    volumes:
      - /var/lib/caddy/.local/share/caddy:/caddy-data:ro
COMPOSE

cd "$DIR/node"
docker compose pull -q 2>/dev/null || docker compose pull
docker compose up -d --force-recreate
ok "Нода запущена"

# Нода и панель — разные compose-проекты, поэтому запуск ноды не может
# задеть панель. Но проверить стоит: без панели дальше идти незачем.
if ! curl -fsS --max-time 5 http://127.0.0.1:3001/health >/dev/null 2>&1; then
  warn "Панель не отвечает после запуска ноды — поднимаю её обратно"
  ( cd "$DIR/panel" && docker compose up -d ) >/dev/null 2>&1 || true
  sleep 10
fi

# 9.8 Ждём подключения ноды к панели
printf '    жду подключения ноды'
NODE_OK=0
for _ in $(seq 1 40); do
  # api() при обрыве вернёт пустоту — jq не должен ронять скрипт.
  resp=$(api "${auth_hdr[@]}" "$API/nodes" 2>/dev/null || true)
  st=$(printf '%s' "$resp" | jq -r '.response[0].isConnected // false' 2>/dev/null || echo false)
  if [[ "$st" == "true" ]]; then NODE_OK=1; break; fi
  printf '.'; sleep 3
done
printf '\n'
if [[ "$NODE_OK" == "1" ]]; then
  ok "Нода подключена к панели"
else
  warn "Нода пока не подключилась. Диагностика:"
  NODE_ERR="$(docker logs --tail 200 remnanode 2>&1 | grep -E "address already in use|no such file|failed to parse certificate|permission denied|invalid|error" -i | tail -3 || true)"
  if [[ -n "$NODE_ERR" ]]; then
    warn "Причина из лога ноды:"
    printf '%s\n' "$NODE_ERR" | sed 's/^/      /'
  else
    docker logs --tail 15 remnanode || true
  fi
  warn "Нода не подключилась. Проверьте: ss -lunp | grep 443  (порт для Hysteria2)"
fi

# 9.9 Порт ноды 2222 снаружи не нужен: панель ходит на неё из docker-сети.
# Закрываем публичный доступ, разрешаем только subnet сети nsky.
# Если нода перестанет быть видна панели — правило откатывается автоматически:
# работающий VPN важнее идеальной закрытости.
if [[ "$NODE_OK" == "1" ]]; then
  NSKY_SUBNET="$(docker network inspect nsky --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
  if [[ -n "$NSKY_SUBNET" ]]; then
    ufw delete allow "$NODE_PORT/tcp" >/dev/null 2>&1 || true
    ufw allow from "$NSKY_SUBNET" to any port "$NODE_PORT" proto tcp >/dev/null
    ok "Порт ноды $NODE_PORT/tcp закрыт снаружи (разрешён только $NSKY_SUBNET)"
    st="false"
    for _ in $(seq 1 20); do
      sleep 3
      resp=$(api "${auth_hdr[@]}" "$API/nodes" 2>/dev/null || true)
      st=$(printf '%s' "$resp" | jq -r '.response[0].isConnected // false' 2>/dev/null || echo false)
      [[ "$st" == "true" ]] && break
    done
    if [[ "$st" == "true" ]]; then
      ok "Нода работает за закрытым портом"
    else
      ufw delete allow from "$NSKY_SUBNET" to any port "$NODE_PORT" proto tcp >/dev/null 2>&1 || true
      ufw allow "$NODE_PORT/tcp" >/dev/null
      warn "Нода не видна панели за закрытым портом — правило откачено (2222 снова открыт)"
    fi
  else
    warn "Не удалось узнать subnet сети nsky — порт ноды $NODE_PORT оставлен открытым"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "10/10. Проверка и тестовая учётка"
# ─────────────────────────────────────────────────────────────────────────────
# Тестовый пользователь (без него подписку не проверить).
TEST_USER="nsky-test"
resp=$(api "${auth_hdr[@]}" "$API/users/by-username/$TEST_USER" 2>/dev/null || echo '{}')
TEST_SUB="$(printf '%s' "$resp" | json_field '.response.shortUuid')"

if [[ -z "$TEST_SUB" ]]; then
  body=$(jq -n --arg u "$TEST_USER" --arg s "$SQUAD_UUID" '{
      username:$u,
      status:"ACTIVE",
      trafficLimitBytes:0,
      trafficLimitStrategy:"NO_RESET",
      expireAt:"2099-01-01T00:00:00.000Z",
      description:"Тестовая учётка NSky, срок до 2099",
      activeInternalSquads:[$s]
    }')
  resp=$(api -X POST "$API/users" "${auth_hdr[@]}" -H 'Content-Type: application/json' -d "$body")
  TEST_SUB=$(printf '%s' "$resp" | json_field '.response.shortUuid')
  if [[ -n "$TEST_SUB" ]]; then ok "Тестовый пользователь создан: $TEST_USER"; fi
else
  ok "Тестовый пользователь уже есть: $TEST_USER"
fi
SUB_URL=""
LINKS_OK=0
if [[ -n "$TEST_SUB" ]]; then
  state_set TEST_SHORT_UUID "$TEST_SUB"
  SUB_URL="https://$DOMAIN/$SUB_SECRET/api/sub/$TEST_SUB"
  state_set SUB_URL "$SUB_URL"

  # Панель требует заголовков прокси, иначе 403.
  SUB_RAW="$(curl -sS --max-time 20 \
    -H 'x-forwarded-for: 127.0.0.1' -H 'x-forwarded-proto: https' \
    "$API/sub/$TEST_SUB" 2>/dev/null || true)"

  # Панель может отдать список как есть или в base64 (зависит от User-Agent).
  # Никаких grep: при pipefail ноль совпадений роняет весь скрипт.
  SUB_TEXT="$SUB_RAW"
  case "$SUB_RAW" in
    *"://"*) : ;;
    *)
      DECODED="$(printf '%s' "$SUB_RAW" | base64 -d 2>/dev/null || true)"
      case "$DECODED" in *"://"*) SUB_TEXT="$DECODED" ;; esac
      ;;
  esac

  COUNT=0
  PROTO_FOUND=""
  for proto in vless hysteria2 trojan ss; do
    n=$(printf '%s' "$SUB_TEXT" | awk -v p="$proto" 'index($0, p "://") == 1 {c++} END {print c+0}')
    if [[ "${n:-0}" -gt 0 ]]; then
      COUNT=$(( COUNT + n ))
      PROTO_FOUND="$PROTO_FOUND $proto"
    fi
  done

  PROTO_FOUND="$(printf '%s\n' $PROTO_FOUND | awk 'NF' | sort -u | tr '\n' ' ')"
  if [[ "$COUNT" -ge 1 ]]; then
    LINKS_OK=1
    ok "Подписка отдаёт ссылок: $COUNT"
    info "протоколы в подписке:$PROTO_FOUND"
  else
    warn "Подписка пустая или недоступна. Первые символы ответа:"
    printf '%s\n' "$SUB_RAW" | head -c 300; echo
    warn "Проверьте в панели раздел Hosts и привязку сквада к ноде."
  fi
fi

echo
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Установка завершена                                             ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo
echo "  Панель:    https://$DOMAIN:$PANEL_PORT    (только с IP офиса: ${PANEL_ALLOW_FROM:-не ограничено})"
echo "  Логин:     $ADMIN_USER"
echo "  Пароль:    $ADMIN_PASS"
if [[ "$HTTPS_OK" == "1" ]]; then
  echo "  HTTPS:     работает"
else
  echo "  HTTPS:     ждёт DNS или порт 80 (сертификат выпустится сам)"
fi
echo
if [[ -n "$(state_get CASCADE_IP)" ]]; then
  echo "  Каскад:    серверы с пометкой (RU) идут через русский релей $(state_get CASCADE_IP)"
  echo "             мобильным сотрудникам — выбрать в приложении сервер (RU)"
fi
echo "  Протоколы:"
echo "    VLESS + REALITY    $SERVER_IP:$REALITY_PORT/tcp   маскировка под $REALITY_SNI"
echo "    VLESS + XHTTP      $SERVER_IP:$XHTTP_PORT/tcp     path $XHTTP_PATH"
if [[ -n "$TLS_CERT" ]]; then
  echo "    Hysteria2          $SERVER_IP:$HY2_PORT/udp     TLS: $DOMAIN"
else
  echo "    Hysteria2          выключен (нет сертификата — перезапустите скрипт позже)"
fi
echo
if [[ "$LINKS_OK" == "1" ]]; then
  echo "  Ссылка подписки для теста:"
  echo "    $SUB_URL"
  echo
  echo "  Проверка готовым клиентом (Happ, v2rayNG, Streisand):"
  echo "    вставьте ссылку подписки — появится $COUNT сервер(ов)."
else
  echo "  Подписка пока пустая — откройте панель и проверьте раздел Hosts."
fi
echo
echo "  Секреты:   $STATE"
echo "  Откат:     $SNAP_DIR/КАК_ОТКАТИТЬ.txt"
echo "  Лог:       $LOG"
echo
echo "  ── Второй администратор ──────────────────────────────────────"
echo "  Панель Remnawave допускает только ОДНОГО админа: при каждом старте"
echo "  контейнера она оставляет самого старого и удаляет остальных"
echo "  (prisma/seed/seeders/12_verify-admin.ts). Поэтому доступ второму"
echo "  человеку выдаётся так:"
echo "    1) Users → Create user — заведите ему обычного пользователя;"
echo "    2) панель → Settings → API Tokens — создайте отдельный токен"
echo "       и передайте его вместе с адресом панели."
echo "  Такой токен живёт в отдельной таблице и не удаляется."
echo
echo "══════════════════════════════════════════════════════════════════"
