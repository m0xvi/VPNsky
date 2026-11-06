#!/usr/bin/env bash
#
# NSky — настройка протоколов и ноды.
#
# Учитывает то, что было выяснено на живом сервере:
#   1. Панель сама создаёт профиль 'Default-Profile' (Shadowsocks).
#      Значит, просто POST /config-profiles даёт 400 — профиль уже есть.
#      Правильный путь: найти существующий профиль и обновить его (PATCH).
#   2. xray лежит в образе ноды по пути /usr/local/bin/xray, не в PATH.
#   3. Панель проверяет Host в SNI-верификации: запросы к API делать
#      через https://<домен>, а не на 127.0.0.1.
#   4. Скрипт печатает реальные коды и тела ответов на каждом шаге.
#
# Использование:
#   bash configure.sh <домен>
#
# Безопасно запускать повторно.

set -uo pipefail

DOMAIN="${1:-vpn.example.com}"
DIR="/opt/nsky"
STATE="$DIR/install-state.env"
API="https://${DOMAIN}/api"
API_LOCAL="http://127.0.0.1:3000/api"

bold() { printf '\n\033[1;36m══ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { bad "Нужен root"; exit 1; }
[[ -f "$STATE" ]] || { bad "Нет $STATE"; exit 1; }
# shellcheck disable=SC1090
source "$STATE"

ADMIN_USER="${ADMIN_USER:-admin}"
if [[ -z "${ADMIN_PASS:-}" ]]; then
  bad "В $STATE нет ADMIN_PASS"
  echo "  Задайте вручную:  echo 'ADMIN_PASS=ваш_пароль' >> $STATE"
  exit 1
fi

# requests — с Host домена, как требует проверка панели
req() {
  curl -sS --max-time 30 --resolve "${DOMAIN}:443:127.0.0.1" "$@"
}
req_code() {
  curl -sS --max-time 30 --resolve "${DOMAIN}:443:127.0.0.1" -w '\n%{http_code}' "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
bold "1/6. Вход администратора"
# ─────────────────────────────────────────────────────────────────────────────
BODY=$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{username:$u,password:$p}')

R=$(curl -sS --max-time 30 --resolve "${DOMAIN}:443:127.0.0.1" \
  -H 'X-Remnawave-Client-Type: browser' -w '\n%{http_code}' \
  -X POST "$API/auth/login" -H 'Content-Type: application/json' -d "$BODY")
CODE=$(echo "$R" | tail -1); BODYRESP=$(echo "$R" | sed '$d')
echo "  вход → HTTP $CODE"
TOKEN=$(echo "$BODYRESP" | jq -r '.response.accessToken // empty' 2>/dev/null || true)

if [[ -z "$TOKEN" ]]; then
  echo "  тело: $BODYRESP"
  warn "Пробую на 127.0.0.1 (без проверки Host)"
  R=$(curl -sS --max-time 20 -w '\n%{http_code}' -X POST "$API_LOCAL/auth/login" \
    -H 'Content-Type: application/json' -d "$BODY")
  CODE=$(echo "$R" | tail -1); BODYRESP=$(echo "$R" | sed '$d')
  echo "  вход локально → HTTP $CODE"
  TOKEN=$(echo "$BODYRESP" | jq -r '.response.accessToken // empty' 2>/dev/null || true)
fi

if [[ -z "$TOKEN" ]]; then
  warn "Вход не прошёл — пробую зарегистрировать администратора"
  R=$(curl -sS --max-time 30 --resolve "${DOMAIN}:443:127.0.0.1" \
  -H 'X-Remnawave-Client-Type: browser' -w '\n%{http_code}' \
  -X POST "$API/auth/register" -H 'Content-Type: application/json' -d "$BODY")
  CODE=$(echo "$R" | tail -1); REGRESP=$(echo "$R" | sed '$d')
  echo "  регистрация → HTTP $CODE"
  TOKEN=$(echo "$REGRESP" | jq -r '.response.accessToken // empty' 2>/dev/null || true)
  if [[ -n "$TOKEN" ]]; then
    ok "Администратор создан: ${ADMIN_USER}"
  fi
fi

if [[ -z "$TOKEN" ]]; then
  bad "Ни вход, ни регистрация не прошли."
  echo "  тело: $BODYRESP"
  echo
  echo "  Значит, администратор уже есть, но пароль в $STATE другой."
  echo "  Варианты:"
  echo "   1) Вспомнить пароль, которым входили на https://$DOMAIN"
  echo "   2) Сбросить администратора (пользователи не пострадают):"
  echo "      docker exec remnawave-db psql -U remnawave -d remnawave -c 'DELETE FROM admin;'"
  echo "      bash configure.sh $DOMAIN"
  exit 2
fi
ok "Токен получен"

# Панель с JWT принимает только запросы с этим заголовком:
# без него — 403 'For API requests you must create own API-token'.
# С api-token (ROLE.API) заголовок не нужен, с JWT (ROLE.ADMIN) — обязателен.
AUTH="Authorization: Bearer $TOKEN"
CLIENT_HDR="X-Remnawave-Client-Type: browser"
req()      { curl -sS --max-time 30 --resolve "${DOMAIN}:443:127.0.0.1" -H "$CLIENT_HDR" "$@"; }
req_code() { curl -sS --max-time 30 --resolve "${DOMAIN}:443:127.0.0.1" -H "$CLIENT_HDR" -w '\n%{http_code}' "$@"; }

# ─────────────────────────────────────────────────────────────────────────────
bold "2/6. Ключи REALITY"
# ─────────────────────────────────────────────────────────────────────────────
REALITY_OUT="$(docker run --rm --entrypoint /usr/local/bin/xray remnawave/node:3.4.4 x25519 2>&1 || true)"
echo "  вывод x25519: $(echo "$REALITY_OUT" | tr '\n' ' ' | head -c 300)"

REALITY_PRIV="$(echo "$REALITY_OUT" | grep -iE "private" | sed 's/.*[Pp]rivate[^:]*:[[:space:]]*//' | tr -d ' \r' | head -1 || true)"
REALITY_PUB="$(echo "$REALITY_OUT"  | grep -iE "public"  | sed 's/.*[Pp]ublic[^:]*:[[:space:]]*//'  | tr -d ' \r' | head -1 || true)"

if [[ -z "$REALITY_PRIV" ]]; then
  REALITY_PRIV="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
  warn "x25519 не сработал — ключ сгенерирован случайно (соединение может не установиться)"
else
  ok "priv: ${REALITY_PRIV:0:12}… pub: ${REALITY_PUB:0:12}…"
fi
REALITY_SHORT_ID="$(openssl rand -hex 8)"
REALITY_SNI="www.microsoft.com"
XHTTP_PATH="/$(openssl rand -hex 4)"
ok "shortId: $REALITY_SHORT_ID, путь XHTTP: $XHTTP_PATH"

# ─────────────────────────────────────────────────────────────────────────────
bold "3/6. Профиль конфигурации"
# ─────────────────────────────────────────────────────────────────────────────
PROFILE_JSON=$(cat <<JSON
{
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
  "outbounds": [
    { "protocol": "freedom", "tag": "DIRECT" },
    { "protocol": "blackhole", "tag": "BLOCK" }
  ]
}
JSON
)

# Ищем существующие профили
R=$(req_code "$API/config-profiles" -H "$AUTH")
CODE=$(echo "$R" | tail -1); LIST=$(echo "$R" | sed '$d')
echo "  список профилей → HTTP $CODE"
PROFILE_UUID=$(echo "$LIST" | jq -r '.response.configProfiles[0].uuid // .response[0].uuid // empty' 2>/dev/null || true)
PROFILE_NAME=$(echo "$LIST" | jq -r '.response.configProfiles[0].name // .response[0].name // empty' 2>/dev/null || true)
echo "  найден профиль: ${PROFILE_NAME:-нет} (${PROFILE_UUID:-—})"

if [[ -n "$PROFILE_UUID" ]]; then
  # Профиль есть (панель создаёт Default-Profile) — обновляем его конфиг.
  BODY_UP=$(jq -n --arg u "$PROFILE_UUID" --arg n "nsky-main" --argjson c "$PROFILE_JSON" \
    '{uuid:$u, name:$n, config:$c}')
  R=$(req_code -X PATCH "$API/config-profiles" -H "$AUTH" -H 'Content-Type: application/json' -d "$BODY_UP")
  CODE=$(echo "$R" | tail -1); RESP=$(echo "$R" | sed '$d')
  echo "  обновление профиля → HTTP $CODE"
  if [[ "$CODE" = "2"* ]]; then
    ok "Профиль обновлён: nsky-main"
  else
    bad "Обновление не удалось"; echo "$RESP" | head -c 500; echo
    exit 3
  fi
else
  BODY_NEW=$(jq -n --arg n "nsky-main" --argjson c "$PROFILE_JSON" '{name:$n, config:$c}')
  R=$(req_code -X POST "$API/config-profiles" -H "$AUTH" -H 'Content-Type: application/json' -d "$BODY_NEW")
  CODE=$(echo "$R" | tail -1); RESP=$(echo "$R" | sed '$d')
  echo "  создание профиля → HTTP $CODE"
  if [[ "$CODE" = "2"* ]]; then
    PROFILE_UUID=$(echo "$RESP" | jq -r '.response.uuid // empty')
    ok "Профиль создан: $PROFILE_UUID"
  else
    bad "Создание не удалось"; echo "$RESP" | head -c 500; echo
    exit 3
  fi
fi

# Инбаунды профиля
R=$(req_code "$API/config-profiles/$PROFILE_UUID/inbounds" -H "$AUTH")
CODE=$(echo "$R" | tail -1); INB=$(echo "$R" | sed '$d')
echo "  инбаунды → HTTP $CODE"
INB_LIST=$(echo "$INB" | jq -r '.response[]? | "\(.tag) \(.protocol) \(.network) \(.security) :\(.port)"' 2>/dev/null)
echo "$INB_LIST" | sed 's/^/    /'
INB_UUIDS=$(echo "$INB" | jq -c '[.response[]?.uuid]' 2>/dev/null || echo '[]')
echo "  UUID инбаундов: $INB_UUIDS"

if [[ "$INB_UUIDS" = "[]" ]]; then
  bad "У профиля нет инбаундов — нода не сможет работать"
  exit 4
fi

{
  echo "PROFILE_UUID=$PROFILE_UUID"
  echo "REALITY_PUB=$REALITY_PUB"
  echo "REALITY_SNI=$REALITY_SNI"
  echo "REALITY_SHORT_ID=$REALITY_SHORT_ID"
  echo "XHTTP_PATH=$XHTTP_PATH"
} >> "$STATE"
ok "Параметры сохранены в $STATE"

# ─────────────────────────────────────────────────────────────────────────────
bold "4/6. Нода"
# ─────────────────────────────────────────────────────────────────────────────
R=$(req_code "$API/nodes" -H "$AUTH")
CODE=$(echo "$R" | tail -1); NODES=$(echo "$R" | sed '$d')
NODE_UUID=$(echo "$NODES" | jq -r '.response[0].uuid // empty' 2>/dev/null || true)
echo "  существующие ноды → HTTP $CODE, найдено: $(echo "$NODES" | jq -r '.response | length' 2>/dev/null || echo 0)"

if [[ -n "$NODE_UUID" ]]; then
  ok "Нода уже есть: $NODE_UUID (профиль привяжем заново)"
  BODY_N=$(jq -n --arg u "$NODE_UUID" --arg pu "$PROFILE_UUID" --argjson inb "$INB_UUIDS" \
    '{uuid:$u, configProfile:{activeConfigProfileUuid:$pu, activeInbounds:$inb}}')
  R=$(req_code -X PATCH "$API/nodes" -H "$AUTH" -H 'Content-Type: application/json' -d "$BODY_N")
  CODE=$(echo "$R" | tail -1); echo "  привязка профиля → HTTP $CODE"
else
  BODY_N=$(jq -n --arg n "nsky-1" --arg a "$SERVER_IP" --arg pu "$PROFILE_UUID" --argjson inb "$INB_UUIDS" \
    '{name:$n, address:$a, port:2222, isTrafficTrackingActive:false,
      configProfile:{activeConfigProfileUuid:$pu, activeInbounds:$inb}}')
  R=$(req_code -X POST "$API/nodes" -H "$AUTH" -H 'Content-Type: application/json' -d "$BODY_N")
  CODE=$(echo "$R" | tail -1); RESP=$(echo "$R" | sed '$d')
  echo "  создание ноды → HTTP $CODE"
  NODE_UUID=$(echo "$RESP" | jq -r '.response.uuid // empty' 2>/dev/null || true)
  if [[ -z "$NODE_UUID" ]]; then
    bad "Нода не создана"; echo "$RESP" | head -c 600; echo; exit 5
  fi
  ok "Нода создана: $NODE_UUID"
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "5/6. Ключ ноды и запуск"
# ─────────────────────────────────────────────────────────────────────────────
R=$(req_code "$API/keygen" -H "$AUTH")
CODE=$(echo "$R" | tail -1); KEYRESP=$(echo "$R" | sed '$d')
NODE_SECRET=$(echo "$KEYRESP" | jq -r '.response.secretKey // empty' 2>/dev/null || true)
echo "  ключ ноды → HTTP $CODE"

if [[ -z "$NODE_SECRET" ]]; then
  bad "Ключ не получен"; echo "$KEYRESP" | head -c 400; echo; exit 6
fi
ok "Ключ получен"

grep -q '^NODE_SECRET=' "$STATE" && sed -i '/^NODE_SECRET=/d' "$STATE"
grep -q '^NODE_UUID=' "$STATE"   && sed -i '/^NODE_UUID=/d'   "$STATE"
echo "NODE_UUID=$NODE_UUID"     >> "$STATE"
echo "NODE_SECRET=$NODE_SECRET" >> "$STATE"

mkdir -p "$DIR/node/certs"
[[ -f "$DIR/node/certs/cert.pem" ]] || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$DIR/node/certs/key.pem" -out "$DIR/node/certs/cert.pem" \
  -subj "/CN=${DOMAIN}" >/dev/null 2>&1

cat > "$DIR/node/docker-compose.yml" <<EOF
services:
  remnanode:
    image: remnawave/node:3.4.4
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

# ─────────────────────────────────────────────────────────────────────────────
bold "6/6. Проверка"
# ─────────────────────────────────────────────────────────────────────────────
sleep 8
R=$(req_code "$API/nodes" -H "$AUTH")
echo "  статус ноды:"
echo "$R" | sed '$d' | jq -r '.response[]? | "    \(.name): connected=\(.isConnected) disabled=\(.isDisabled) profile=\(.configProfile.activeConfigProfileUuid // "-")"' 2>/dev/null

echo
echo "════════════════════════════════════════════════════════════"
echo "  Готово. Панель: https://${DOMAIN}"
echo "  Профиль: nsky-main"
echo "    • VLESS + REALITY  443/tcp"
echo "    • VLESS + XHTTP    8443/tcp"
echo
echo "  Дальше: Users → Create user → ссылка подписки"
echo "  Для клиента: nsky://install-config?url=<ссылка>"
echo "════════════════════════════════════════════════════════════"
