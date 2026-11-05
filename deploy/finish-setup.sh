#!/usr/bin/env bash
#
# NSky — донастройка после основного скрипта.
#
# Запускать, если setup-server.sh остановился на шаге 7 или 8:
#   • администратор не создался
#   • нода не запущена
#   • HTTPS не выпустился
#
# Скрипт показывает НАСТОЯЩУЮ ошибку панели, а не «не получилось».
# Безопасно запускать повторно.
#
# Использование:
#   bash finish-setup.sh <домен>

set -uo pipefail

DOMAIN="${1:-oijas.rknmrz.xyz}"
DIR="/opt/nsky"
STATE="$DIR/install-state.env"
API="http://127.0.0.1:3000/api"

bold() { printf '\n\033[1;36m══ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { bad "Запустите от root"; exit 1; }
[[ -f "$STATE" ]] || { bad "Нет $STATE — сначала запустите setup-server.sh"; exit 1; }
# shellcheck disable=SC1090
source "$STATE"

# Пароль администратора мог не сохраниться в старом запуске — восстановим.
if [[ -z "${ADMIN_PASS:-}" ]]; then
  ADMIN_PASS="$(printf '%sAa9' "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')")"
  echo "ADMIN_PASS=$ADMIN_PASS" >> "$STATE"
  warn "Пароль был не сохранён, сгенерирован новый"
fi
ADMIN_USER="${ADMIN_USER:-admin}"

# ─────────────────────────────────────────────────────────────────────────────
bold "1/6. Проверка панели"
# ─────────────────────────────────────────────────────────────────────────────
if ! curl -fsS --max-time 5 http://127.0.0.1:3001/health >/dev/null 2>&1; then
  bad "Панель не отвечает. Запустите: cd $DIR/panel && docker compose up -d"
  exit 1
fi
ok "Панель отвечает"

STATUS=$(curl -sS --max-time 10 "$API/auth/status" 2>&1)
echo "  ответ статуса: $STATUS"
IS_REG=$(echo "$STATUS" | jq -r '.response.isRegisterAllowed // "?"' 2>/dev/null || echo "?")
IS_LOGIN=$(echo "$STATUS" | jq -r '.response.isLoginAllowed // "?"' 2>/dev/null || echo "?")
ok "Регистрация разрешена: $IS_REG | Вход разрешён: $IS_LOGIN"

# ─────────────────────────────────────────────────────────────────────────────
bold "2/6. Администратор"
# ─────────────────────────────────────────────────────────────────────────────
TOKEN=""

try_register() {
  local body resp code
  body=$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{username:$u,password:$p}')
  resp=$(curl -sS --max-time 20 -w '\n%{http_code}' -X POST "$API/auth/register" \
    -H 'Content-Type: application/json' -d "$body" 2>&1)
  code=$(echo "$resp" | tail -1)
  resp=$(echo "$resp" | sed '$d')
  echo "  регистрация → HTTP $code"
  if [[ "$code" != "2"* ]]; then
    echo "  тело ответа: $resp"
  fi
  echo "$resp" | jq -r '.response.accessToken // empty' 2>/dev/null
}

try_login() {
  local body resp code
  body=$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{username:$u,password:$p}')
  resp=$(curl -sS --max-time 20 -w '\n%{http_code}' -X POST "$API/auth/login" \
    -H 'Content-Type: application/json' -d "$body" 2>&1)
  code=$(echo "$resp" | tail -1)
  resp=$(echo "$resp" | sed '$d')
  echo "  вход → HTTP $code"
  if [[ "$code" != "2"* ]]; then
    echo "  тело ответа: $resp"
  fi
  echo "$resp" | jq -r '.response.accessToken // empty' 2>/dev/null
}

if [[ "$IS_REG" = "false" && "$IS_LOGIN" = "false" ]]; then
  bad "Панель не разрешает ни вход, ни регистрацию."
  warn "Значит, администратор уже создан, но с другим паролем."
  warn "Варианты:"
  warn "  1) Войти тем паролем, который вы задавали при первом открытии панели"
  warn "  2) Сбросить: docker exec remnawave-db psql -U remnawave -d remnawave -c 'DELETE FROM admin;'"
  warn "     затем запустить этот скрипт снова"
  exit 2
fi

if [[ "$IS_REG" = "true" ]]; then
  TOKEN="$(try_register)"
fi
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(try_login)"
fi

if [[ -z "$TOKEN" ]]; then
  bad "Не удалось ни зарегистрировать, ни войти."
  exit 3
fi
ok "Токен администратора получен"

# ─────────────────────────────────────────────────────────────────────────────
bold "3/6. API-токен"
# ─────────────────────────────────────────────────────────────────────────────
TOK_RESP=$(curl -sS --max-time 20 -X POST "$API/tokens" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"nsky-admin","expiresInDays":3650}' 2>&1)
API_TOKEN=$(echo "$TOK_RESP" | jq -r '.response.token // empty' 2>/dev/null || true)
if [[ -n "$API_TOKEN" ]]; then
  grep -q '^API_TOKEN=' "$STATE" && sed -i '/^API_TOKEN=/d' "$STATE"
  echo "API_TOKEN=$API_TOKEN" >> "$STATE"
  ok "API-токен создан"
else
  warn "API-токен не создан: $TOK_RESP"
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "4/6. HTTPS"
# ─────────────────────────────────────────────────────────────────────────────
if curl -fsS --max-time 10 "https://$DOMAIN" >/dev/null 2>&1; then
  ok "HTTPS работает"
else
  warn "HTTPS не отвечает. Диагностика:"
  echo "  --- статус caddy ---"
  systemctl is-active caddy 2>&1 | sed 's/^/  /'
  echo "  --- последние строки журнала ---"
  journalctl -u caddy -n 25 --no-pager 2>&1 | sed 's/^/  /'
  echo
  echo "  Частые причины:"
  echo "   • порт 80 закрыт у хостера (не в ufw) — проверьте панель хостинга"
  echo "   • домен ещё не указывает на этот IP"
  echo "   • Caddy не успел получить сертификат — подождите 2-3 минуты"
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "5/6. Профиль Xray"
# ─────────────────────────────────────────────────────────────────────────────
PROFILE_UUID=$(grep -m1 '^PROFILE_UUID=' "$STATE" 2>/dev/null | cut -d= -f2 || true)

if [[ -z "$PROFILE_UUID" ]]; then
  ok "Генерирую ключи REALITY"
  docker pull -q remnawave/node:3 >/dev/null 2>&1 || true
  REALITY_OUT="$(docker run --rm --entrypoint xray remnawave/node:3 x25519 2>/dev/null || true)"
  echo "  вывод x25519: $(echo "$REALITY_OUT" | tr '\n' ' ')"
  REALITY_PRIV="$(echo "$REALITY_OUT" | grep -iE "private" | awk -F': *' '{print $2}' | tr -d ' \r' | head -1 || true)"
  REALITY_PUB="$(echo "$REALITY_OUT"  | grep -iE "public"  | awk -F': *' '{print $2}' | tr -d ' \r' | head -1 || true)"
  if [[ -z "$REALITY_PRIV" ]]; then
    REALITY_PRIV="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
    warn "x25519 недоступен — сгенерирован случайный ключ"
  fi
  REALITY_SHORT_ID="$(openssl rand -hex 8)"
  REALITY_SNI="www.microsoft.com"
  XHTTP_PATH="/$(openssl rand -hex 4)"

  PROFILE_JSON=$(cat <<JSON
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
JSON
)

  RESP=$(curl -sS --max-time 30 -w '\n%{http_code}' -X POST "$API/config-profiles" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$PROFILE_JSON" 2>&1)
  CODE=$(echo "$RESP" | tail -1); RESP=$(echo "$RESP" | sed '$d')
  echo "  создание профиля → HTTP $CODE"
  PROFILE_UUID=$(echo "$RESP" | jq -r '.response.uuid // empty' 2>/dev/null || true)

  if [[ -z "$PROFILE_UUID" ]]; then
    bad "Профиль не создан. Ответ: $RESP"
  else
    ok "Профиль создан: $PROFILE_UUID"
    {
      echo "PROFILE_UUID=$PROFILE_UUID"
      echo "REALITY_PUB=$REALITY_PUB"
      echo "REALITY_SNI=$REALITY_SNI"
      echo "REALITY_SHORT_ID=$REALITY_SHORT_ID"
      echo "XHTTP_PATH=$XHTTP_PATH"
    } >> "$STATE"
  fi
else
  ok "Профиль уже создан: $PROFILE_UUID"
fi

# ─────────────────────────────────────────────────────────────────────────────
bold "6/6. Нода"
# ─────────────────────────────────────────────────────────────────────────────
if [[ -n "${NODE_SECRET:-}" ]]; then
  ok "Нода уже настроена, перезапускаю"
  cd "$DIR/node" && docker compose up -d && ok "Нода запущена"
else
  if [[ -z "$PROFILE_UUID" ]]; then
    bad "Нет профиля — нода невозможна. Исправьте шаг 5."
    exit 4
  fi

  INB=$(curl -sS --max-time 20 "$API/config-profiles/$PROFILE_UUID/inbounds" \
    -H "Authorization: Bearer $TOKEN" 2>&1)
  INB_UUIDS=$(echo "$INB" | jq -c '[.response[]?.uuid]' 2>/dev/null || echo '[]')
  echo "  инбаунды: $INB_UUIDS"

  NODE_BODY=$(jq -n --arg n "nsky-1" --arg a "$SERVER_IP" \
    --arg pu "$PROFILE_UUID" --argjson inb "$INB_UUIDS" \
    '{name:$n,address:$a,port:2222,isTrafficTrackingActive:false,
      configProfile:{activeConfigProfileUuid:$pu,activeInbounds:$inb}}')

  RESP=$(curl -sS --max-time 30 -w '\n%{http_code}' -X POST "$API/nodes" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$NODE_BODY" 2>&1)
  CODE=$(echo "$RESP" | tail -1); RESP=$(echo "$RESP" | sed '$d')
  echo "  создание ноды → HTTP $CODE"
  NODE_UUID=$(echo "$RESP" | jq -r '.response.uuid // empty' 2>/dev/null || true)

  if [[ -z "$NODE_UUID" ]]; then
    bad "Нода не создана. Ответ: $RESP"
    exit 5
  fi
  ok "Нода создана: $NODE_UUID"

  KEY_RESP=$(curl -sS --max-time 20 "$API/keygen" -H "Authorization: Bearer $TOKEN" 2>&1)
  NODE_SECRET=$(echo "$KEY_RESP" | jq -r '.response.secretKey // empty' 2>/dev/null || true)
  if [[ -z "$NODE_SECRET" ]]; then
    bad "SECRET_KEY не получен. Ответ: $KEY_RESP"
    exit 6
  fi
  ok "SECRET_KEY получен"

  {
    echo "NODE_UUID=$NODE_UUID"
    echo "NODE_SECRET=$NODE_SECRET"
  } >> "$STATE"

  mkdir -p "$DIR/node/certs"
  [[ -f "$DIR/node/certs/cert.pem" ]] || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$DIR/node/certs/key.pem" -out "$DIR/node/certs/cert.pem" \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1

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
fi

echo
echo "════════════════════════════════════════════════════════════"
echo "  Проверьте в панели: https://${DOMAIN}"
echo "  Nodes → nsky-1 должен быть зелёным (до 30 секунд)"
echo "  Логин: ${ADMIN_USER}"
echo "  Пароль: ${ADMIN_PASS}"
echo "════════════════════════════════════════════════════════════"
echo
echo "  Дальше: Users → Create user → скопировать ссылку подписки"
echo "  Ссылка для клиента: nsky://install-config?url=<ссылка подписки>"
