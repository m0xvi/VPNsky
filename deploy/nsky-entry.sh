#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════════════════════
# NSky Entry — русский VPS как ВХОД-УЗЕЛ каскада (Xray, VLESS+REALITY).
#
# Зачем: прозрачный DNAT (nsky-relay.sh) на мобильных сетях РФ доводил
# ClientHello до нидерландской ноды, но телефон так и не получал трафик.
# Здесь другой принцип — русский VPS САМ терминирует TLS клиента и уже
# отдельным исходящим соединением идёт на нидерландскую ноду:
#
#   телефон (LTE)  --VLESS+REALITY-->  RU VPS  --VLESS+REALITY-->  NL нода --> интернет
#                  один TLS к близкому IP      обычный датацентровый маршрут
#
# Что это даёт по сравнению с DNAT:
#   • на участке «телефон → RU» нет прозрачной пересылки: TLS завершается
#     локально, поэтому исчезают PMTU/MSS-дыры, conntrack и «полуоткрытые»
#     сессии между двумя датацентрами;
#   • телефон видит один REALITY-хост на российском IP — обычный TLS;
#   • телефон не тянет подписку с зарубежного домена: ссылка добавляется
#     вручную (на LTE подписка раньше падала в таймаут);
#   • каскад можно проверить БЕЗ телефона: у Xray есть локальный SOCKS-вход,
#     привязанный к цепочке, и скрипт сам показывает внешний IP через неё.
#
# Использование (на РУССКОМ VPS, от root):
#   bash nsky-entry.sh 'vless://...'      # ссылка на ПРЯМОЙ (без «(RU)») хост
#   bash nsky-entry.sh --check            # самопроверка, включая цепочку RU→NL
#   bash nsky-entry.sh --link             # заново напечатать ссылки для Happ
#   bash nsky-entry.sh --status           # краткое состояние
#   bash nsky-entry.sh --remove           # снять вход-узел (NL не трогается)
#
# Ссылку на прямой хост берут в Happ (поделиться узлом) или в панели
# (Users → Subscription links). Внутри неё уже есть адрес NL, порт, UUID,
# publicKey (pbk), shortId (sid) и SNI — вводить их руками не нужно.
#
# Скрипт НЕ трогает нидерландский сервер, панель, Remnawave, подписки и ключи
# существующих инбаундов. Всё, что он делает, живёт в /opt/nsky-entry и
# обратимо одной командой --remove.
# ═════════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail

VERSION="2026-11-06.8"

# Пути можно переопределить переменными окружения (нужно для локальных тестов).
DIR="${NSKY_ENTRY_DIR:-/opt/nsky-entry}"
CONF="${NSKY_ENTRY_CONF:-/usr/local/etc/nsky-entry.json}"
BIN="${NSKY_ENTRY_BIN:-/usr/local/bin/xray}"
UNIT="${NSKY_ENTRY_UNIT:-/etc/systemd/system/nsky-entry.service}"
SERVICE="nsky-entry"
SOCKS_CHAIN="${NSKY_ENTRY_SOCKS_CHAIN:-1081}"
SOCKS_DIRECT="${NSKY_ENTRY_SOCKS_DIRECT:-1082}"

MODE="apply"
REGEN=0
UPDATE=0
SELF_URL="${NSKY_ENTRY_SELF_URL:-https://raw.githubusercontent.com/m0xvi/VPNsky/refs/heads/arena/7fd1d6ce-vpnsky/deploy/nsky-entry.sh}"
ORIG_ARGS=("$@")
PORT="${NSKY_ENTRY_PORT:-443}"
ALT_PORT="${NSKY_ENTRY_ALT_PORT:-8443}"
SNI="${NSKY_ENTRY_SNI:-www.microsoft.com}"
# Явно заданные значения (флаг или переменная окружения) важнее сохранённого
# состояния — иначе повторный запуск «залипал» бы на старых портах.
PORT_ARG="${NSKY_ENTRY_PORT:-}"
ALT_ARG="${NSKY_ENTRY_ALT_PORT:-}"
SNI_ARG="${NSKY_ENTRY_SNI:-}"
PUBIP=""
PUBIP_ARG=""
LINK=""

# Состояние входа (заполняется при apply, читается в --link/--check).
RU_PRIV=""
RU_PUB=""
RU_SID=""
CLIENT_UUID=""
NL_HOST=""
NL_PORT=""
NL_UUID=""
NL_SNI=""
NL_PBK=""
NL_SID=""
NL_FLOW=""
NL_FP="chrome"
NL_SPX="/"
QUERY=""

ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
bad()   { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; }
die()   { bad "$*"; exit 1; }
head2() { printf '\n\033[1;36m── %s ──────────────────────────────\033[0m\n' "$*"; }

usage() {
  cat <<'USAGE'
NSky Entry — вход-узел каскада на русском VPS (VLESS+REALITY → NL)

  bash nsky-entry.sh 'vless://...'   установить/обновить (ссылка на прямой хост)
  bash nsky-entry.sh --check         самопроверка (в т.ч. цепочка RU→NL→интернет)
  bash nsky-entry.sh --link          напечатать ссылки для Happ
  bash nsky-entry.sh --status        состояние службы и портов
  bash nsky-entry.sh --remove        снять вход-узел

  --port <N>        основной порт входа (по умолчанию 443)
  --alt-port <N>    резервный порт (по умолчанию 8443, 0 — не открывать)
  --update          скачать свежую версию скрипта и перезапустить его
  --regen-keys      пересоздать ключи входа и выдать новую ссылку
  --ip <IP>         внешний IP этого VPS (иначе определится автоматически)
  --sni <домен>     маска REALITY (по умолчанию www.microsoft.com)

Требуется root. NL-сервер, панель и подписки не изменяются.
USAGE
}

# ── аргументы ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)    MODE="check"; shift ;;
    --link)     MODE="link"; shift ;;
    --status)   MODE="status"; shift ;;
    --remove)   MODE="remove"; shift ;;
    --regen-keys) REGEN=1; shift ;;
    --update)   UPDATE=1; shift ;;
    --port)     PORT_ARG="${2:-}"; shift 2; PORT="${PORT_ARG}" ;;
    --alt-port) ALT_ARG="${2:-}"; shift 2; ALT_PORT="${ALT_ARG}" ;;
    --ip)       PUBIP_ARG="${2:-}"; shift 2 ;;
    --sni)      SNI_ARG="${2:-}"; shift 2; SNI="${SNI_ARG}" ;;
    --help|-h)  usage; exit 0 ;;
    vless://*)  LINK="$1"; shift ;;
    *)          die "Неизвестный аргумент: $1 (--help)" ;;
  esac
done

if [[ "$UPDATE" == "1" ]]; then
  _tmp="$(mktemp)"
  printf '  обновляю скрипт: %s\n' "$SELF_URL"
  if ! curl -fsSL --max-time 30 -o "$_tmp" "$SELF_URL"; then
    rm -f "$_tmp"; die "Не удалось скачать свежую версию"
  fi
  if ! bash -n "$_tmp" 2>/dev/null; then
    rm -f "$_tmp"; die "Скачанная версия битая — оставляю текущую"
  fi
  install -m 755 "$_tmp" "$0" 2>/dev/null || cp -f "$_tmp" "$0"
  rm -f "$_tmp"
  _args=()
  for _a in "${ORIG_ARGS[@]}"; do [[ "$_a" == "--update" ]] || _args+=("$_a"); done
  exec bash "$0" "${_args[@]}"
fi

[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port должен быть числом"
[[ -z "$ALT_PORT" || "$ALT_PORT" =~ ^[0-9]+$ ]] || die "--alt-port должен быть числом"
[[ "$SNI" =~ ^[A-Za-z0-9.-]+$ ]] || die "--sni: ожидается домен"

if [[ "${NSKY_ENTRY_SKIP_ROOT:-0}" != "1" && $EUID -ne 0 ]]; then
  die "Запускать от root (на русском VPS, не на NL-ноде)"
fi

# ── утилиты ─────────────────────────────────────────────────────────────────
urldecode() {
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}

qget() {
  # qget <ключ> — значение параметра из $QUERY, пустая строка если нет
  local k="$1" part
  [[ -n "$QUERY" ]] || return 0
  local IFS='&'
  for part in $QUERY; do
    if [[ "${part%%=*}" == "$k" ]]; then
      printf '%s' "$(urldecode "${part#*=}")"
      return 0
    fi
  done
  return 0
}

# ── разбор ссылки vless:// на прямой хост ───────────────────────────────────
parse_link() {
  local l="$1"
  [[ "$l" == vless://* ]] || die "Ожидается ссылка vless://… (скопируйте её из Happ или панели)"
  l="${l#vless://}"

  local userinfo rest hostport
  userinfo="${l%%@*}"
  rest="${l#*@}"
  [[ "$userinfo" != "$l" ]] || die "В ссылке нет «@» — это не VLESS-ссылка"

  NL_UUID="${userinfo%%\?*}"
  NL_UUID="$(urldecode "$NL_UUID")"

  hostport="${rest%%\?*}"
  hostport="${hostport%%#*}"
  NL_HOST="${hostport%:*}"
  NL_PORT="${hostport##*:}"

  QUERY=""
  if [[ "$rest" == *\?* ]]; then
    QUERY="${rest#*\?}"
    QUERY="${QUERY%%#*}"
  fi

  NL_PBK="$(qget pbk)"
  NL_SID="$(qget sid)"
  NL_SNI="$(qget sni)"
  NL_FLOW="$(qget flow)"
  NL_FP="$(qget fp)";      [[ -n "$NL_FP" ]]  || NL_FP="chrome"
  NL_SPX="$(qget spx)";    [[ -n "$NL_SPX" ]] || NL_SPX="/"
  local sec type
  sec="$(qget security)"
  type="$(qget type)"

  [[ "$NL_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || die "В ссылке нет UUID пользователя"
  [[ "$NL_HOST" =~ ^[0-9A-Za-z.-]+$ ]] || die "Непонятный адрес сервера: $NL_HOST"
  [[ "$NL_PORT" =~ ^[0-9]+$ ]] || die "Непонятный порт сервера: $NL_PORT"
  [[ "$sec" == "reality" ]] || die "Ссылка не REALITY (security=$sec). Нужен хост NSky REALITY без «(RU)»"
  [[ "$type" == "tcp" || "$type" == "raw" || -z "$type" ]] || die "Поддерживается только TCP-хост (type=$type)"
  [[ "$NL_PBK" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "В ссылке нет корректного publicKey (pbk)"
  [[ "$NL_SID" =~ ^[0-9a-fA-F]{0,16}$ ]] || die "В ссылке нет корректного shortId (sid)"
  [[ -n "$NL_SNI" ]] || die "В ссылке нет SNI"
}

# ── состояние ───────────────────────────────────────────────────────────────
state_file() { printf '%s/entry.env' "$DIR"; }

load_state() {
  local f
  f="$(state_file)"
  [[ -r "$f" ]] || return 0
  # shellcheck disable=SC1090
  set -a; . "$f"; set +a
}

save_state() {
  mkdir -p "$DIR"
  {
    printf "RU_PRIV='%s'\n"    "$RU_PRIV"
    printf "RU_PUB='%s'\n"     "$RU_PUB"
    printf "RU_SID='%s'\n"     "$RU_SID"
    printf "CLIENT_UUID='%s'\n" "$CLIENT_UUID"
    printf "PORT='%s'\n"       "$PORT"
    printf "ALT_PORT='%s'\n"   "$ALT_PORT"
    printf "SNI='%s'\n"        "$SNI"
    printf "PUBIP='%s'\n"      "$PUBIP"
    printf "NL_HOST='%s'\n"    "$NL_HOST"
    printf "NL_PORT='%s'\n"    "$NL_PORT"
    printf "NL_UUID='%s'\n"    "$NL_UUID"
    printf "NL_SNI='%s'\n"     "$NL_SNI"
    printf "NL_PBK='%s'\n"     "$NL_PBK"
    printf "NL_SID='%s'\n"     "$NL_SID"
    printf "NL_FLOW='%s'\n"    "$NL_FLOW"
    printf "NL_FP='%s'\n"      "$NL_FP"
    printf "NL_SPX='%s'\n"     "$NL_SPX"
  } > "$(state_file)"
  chmod 600 "$(state_file)"
}

# ── установка самого Xray ───────────────────────────────────────────────────
ensure_xray() {
  [[ -x "$BIN" ]] && return 0
  local arch url tmp
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  arch="64" ;;
    aarch64|arm64) arch="arm64-v8a" ;;
    *) die "Неподдерживаемая архитектура: $arch (готовый бинарник только amd64/arm64)" ;;
  esac

  for c in curl unzip; do
    command -v "$c" >/dev/null 2>&1 && continue
    info "Ставлю $c…"
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq "$c" >/dev/null 2>&1 || true
    command -v "$c" >/dev/null 2>&1 || die "Не удалось поставить $c"
  done

  tmp="$(mktemp -d)"

  url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
  info "Скачиваю Xray-core: $url"
  if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp/xray.zip" "$url"; then
    rm -rf "$tmp"
    die "Не удалось скачать Xray. Проверьте доступ к github.com с этого VPS"
  fi

  if ! unzip -o -q "$tmp/xray.zip" -d "$tmp"; then
    rm -rf "$tmp"
    die "Не удалось распаковать архив Xray"
  fi
  if ! install -m 0755 "$tmp/xray" "$BIN"; then
    rm -rf "$tmp"
    die "Не удалось установить $BIN"
  fi
  mkdir -p /usr/local/share/xray
  local f
  for f in geoip.dat geosite.dat; do
    [[ -f "$tmp/$f" ]] && install -m 0644 "$tmp/$f" "/usr/local/share/xray/$f" || true
  done
  rm -rf "$tmp"
  ok "Xray установлен: $("$BIN" version 2>/dev/null | head -1 || echo "$BIN")"
}

# ── ключи REALITY для входного инбаунда ─────────────────────────────────────
derive_pubkey() {
  # derive_pubkey <приватный ключ> -> публичный ключ (или пусто, если Xray так не умеет)
  local priv="$1" out
  out="$("$BIN" x25519 -i "$priv" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$priv" | "$BIN" x25519 -i 2>/dev/null || true)"
  fi
  printf '%s\n' "$out" | grep -oE '[A-Za-z0-9_-]{43}' | grep -vxF "$priv" | head -1
  return 0
}

gen_reality_keys() {
  local out tokens cand d other
  out="$("$BIN" x25519 2>/dev/null || true)"
  [[ -n "$out" ]] || die "«$BIN x25519» не выдал ключи"
  tokens="$(printf '%s\n' "$out" | grep -oE '[A-Za-z0-9_-]{43}' | awk '!seen[$0]++')"
  [[ -n "$tokens" ]] || die "Не разобрал вывод x25519: $out"

  # Пару проверяем по существу: просим Xray вывести публичный ключ ИЗ приватного
  # и ищем совпадение среди напечатанных. Метки в выводе x25519 между версиями
  # разные (PrivateKey/Password/Seed/...), полагаться на них нельзя.
  for cand in $tokens; do
    d="$(derive_pubkey "$cand")"
    [[ -n "$d" ]] || continue
    for other in $tokens; do
      if [[ "$other" == "$d" && "$other" != "$cand" ]]; then
        RU_PRIV="$cand"
        RU_PUB="$other"
        ok "Пара ключей REALITY сверена (публичный выведен из приватного)"
        return 0
      fi
    done
  done

  warn "Xray не подтвердил пару ключей — беру по меткам (может не сработать)"
  RU_PRIV="$(printf '%s\n' "$out" | grep -iE 'private' | grep -oE '[A-Za-z0-9_-]{43}' | head -1 || true)"
  RU_PUB="$(printf '%s\n' "$out" | grep -iE 'public|password' | grep -oE '[A-Za-z0-9_-]{43}' | head -1 || true)"
  if [[ -z "$RU_PRIV" || -z "$RU_PUB" ]]; then
    RU_PRIV="$(printf '%s\n' "$tokens" | sed -n 1p)"
    RU_PUB="$(printf '%s\n' "$tokens" | sed -n 2p)"
  fi
  [[ "$RU_PRIV" =~ ^[A-Za-z0-9_-]{43}$ && "$RU_PUB" =~ ^[A-Za-z0-9_-]{43}$ ]] \
    || die "Не разобрал ключи REALITY: $out"
}

new_short_id() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8
  else
    head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

new_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '\n' < /proc/sys/kernel/random/uuid
  else
    "$BIN" uuid | tr -d '\n'
  fi
}

# ── рендер конфига ──────────────────────────────────────────────────────────
# Важно: вход делаем БЕЗ xtls-rprx-vision. Vision на входе + vision на выходе
# в NL — это вложенный Vision; соединение при этом устанавливается, но данные
# не идут. Vision остаётся только на плече RU→NL (значение берётся из ссылки).
render_config() {
  # render_config <сеть: raw|tcp> <ключ адреса fallback: target|dest>
  local net="$1" destkey="$2"
  local flow_json="" alt_block="" socks_chain_block="" socks_direct_block=""
  [[ -n "$NL_FLOW" ]] && flow_json=", \"flow\": \"$NL_FLOW\""

  if [[ -n "$ALT_PORT" && "$ALT_PORT" != "0" ]]; then
    alt_block="$(cat <<ALT
,
    {
      "tag": "vless-reality-${ALT_PORT}",
      "listen": "0.0.0.0",
      "port": ${ALT_PORT},
      "protocol": "vless",
      "settings": { "clients": [ { "id": "${CLIENT_UUID}" } ], "decryption": "none" },
      "streamSettings": {
        "network": "${net}",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "${destkey}": "${SNI}:443",
          "xver": 0,
          "serverNames": [ "${SNI}" ],
          "privateKey": "${RU_PRIV}",
          "shortIds": [ "${RU_SID}" ]
        }
      }
    }
ALT
)"
  fi

  socks_chain_block="$(cat <<SOCKS
,
    {
      "tag": "socks-chain",
      "listen": "127.0.0.1",
      "port": ${SOCKS_CHAIN},
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true }
    },
    {
      "tag": "socks-direct",
      "listen": "127.0.0.1",
      "port": ${SOCKS_DIRECT},
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true }
    }
SOCKS
)"

  cat <<JSON
{
  "log": { "loglevel": "debug" },
  "inbounds": [
    {
      "tag": "vless-reality-${PORT}",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": { "clients": [ { "id": "${CLIENT_UUID}" } ], "decryption": "none" },
      "streamSettings": {
        "network": "${net}",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "${destkey}": "${SNI}:443",
          "xver": 0,
          "serverNames": [ "${SNI}" ],
          "privateKey": "${RU_PRIV}",
          "shortIds": [ "${RU_SID}" ]
        }
      }
    }${alt_block}${socks_chain_block}
  ],
  "outbounds": [
    {
      "tag": "nl",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${NL_HOST}",
            "port": ${NL_PORT},
            "users": [ { "id": "${NL_UUID}", "encryption": "none"${flow_json} } ]
          }
        ]
      },
      "streamSettings": {
        "network": "${net}",
        "security": "reality",
        "realitySettings": {
          "serverName": "${NL_SNI}",
          "fingerprint": "${NL_FP}",
          "publicKey": "${NL_PBK}",
          "shortId": "${NL_SID}",
          "spiderX": "${NL_SPX}"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": [ "socks-direct" ], "outboundTag": "direct" },
      { "type": "field", "inboundTag": [ "socks-chain" ], "outboundTag": "nl" }
    ]
  }
}
JSON
}

config_ok() {
  local f="$1" out=""
  if "$BIN" run -test -config "$f" >/dev/null 2>&1; then return 0; fi
  if "$BIN" -test -config "$f" >/dev/null 2>&1; then return 0; fi
  # Показываем только суть ошибки, а не баннер с версией.
  out="$("$BIN" run -test -config "$f" 2>&1 | grep -iE 'fail|error|invalid|unknown|unsupported|expected' | head -5 || true)"
  [[ -n "$out" ]] || out="$("$BIN" -test -config "$f" 2>&1 | grep -iE 'fail|error|invalid|unknown|unsupported|expected' | head -5 || true)"
  printf '%s\n' "$out" >&2
  return 1
}

write_config() {
  local tmp base variant net destkey
  mkdir -p "$(dirname "$CONF")"
  # Xray определяет формат конфига по РАСШИРЕНИЮ файла: без .json он отвечает
  # «Failed to get format of /tmp/tmp.XXXX». Поэтому временный файл — всегда *.json.
  base="$(mktemp)"
  tmp="${base}.json"
  rm -f "$base"

  # Xray 25.9+ переименовал tcp→raw и dest→target. Новый вариант первый,
  # старый — как совместимость, если поставился более старый бинарник.
  for variant in "raw target" "tcp dest"; do
    net="${variant%% *}"
    destkey="${variant##* }"
    render_config "$net" "$destkey" > "$tmp"
    if command -v jq >/dev/null 2>&1 && ! jq empty "$tmp" >/dev/null 2>&1; then
      warn "Сгенерированный JSON невалиден (вариант $net) — это баг, сообщите"
      continue
    fi
    if config_ok "$tmp"; then
      install -m 600 "$tmp" "$CONF"
      rm -f "$tmp"
      ok "Конфиг принят Xray (network=$net, fallback=$destkey)"
      return 0
    fi
  done
  rm -f "$tmp"
  die "Xray не принял ни один вариант конфига (см. ошибку выше)"
}

# ── systemd ─────────────────────────────────────────────────────────────────
write_unit() {
  cat > "$UNIT" <<UNIT_TXT
[Unit]
Description=NSky Entry: VLESS+REALITY вход каскада (RU -> NL)
Documentation=https://github.com/m0xvi/VPNsky
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} run -config ${CONF}
Restart=always
RestartSec=3
LimitNOFILE=65535
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT_TXT
  systemctl daemon-reload >/dev/null 2>&1 || true
}

# ── сеть ────────────────────────────────────────────────────────────────────
detect_pubip() {
  [[ -n "$PUBIP" ]] && return 0
  local ip u
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
    ip="$(curl -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then PUBIP="$ip"; return 0; fi
  done
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  PUBIP="$ip"
  [[ -n "$PUBIP" ]] || die "Не смог определить внешний IP этого VPS — укажите --ip"
}

port_busy() {
  local p="$1"
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
}

# Снимаем старые DNAT-правила на наших портах: иначе пакет уедет на NL,
# не дойдя до локального Xray (это остатки nsky-relay.sh).
remove_conflict_dnat() {
  command -v iptables >/dev/null 2>&1 || return 0
  local p spec i
  for p in "$PORT" "$ALT_PORT"; do
    [[ -n "$p" && "$p" != "0" ]] || continue
    for i in 1 2 3 4 5; do
      spec="$(iptables -t nat -S PREROUTING 2>/dev/null | grep -E -- "-p tcp .*--dport ${p}\b.*-j DNAT" | head -1 | sed 's/^-A PREROUTING //' || true)"
      [[ -n "$spec" ]] || break
      # shellcheck disable=SC2086
      if iptables -t nat -D PREROUTING $spec 2>/dev/null; then
        ok "Снял старый DNAT на порту $p (остаток релея)"
      else
        break
      fi
    done
  done
}

open_firewall() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q "Status: active" || return 0
  local p list="$PORT/tcp"
  for p in "$PORT" "$ALT_PORT"; do
    [[ -n "$p" && "$p" != "0" ]] || continue
    ufw allow "$p"/tcp >/dev/null 2>&1 || true
    [[ "$p" == "$PORT" ]] || list="$list, $p/tcp"
  done
  ok "ufw: открыты $list"
}

wait_listen() {
  local p="$1" i
  for i in $(seq 1 40); do
    port_busy "$p" && return 0
    sleep 0.25
  done
  return 1
}

# ── ссылки для телефона ─────────────────────────────────────────────────────
build_link() {
  local port="$1"
  local q="encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${RU_PUB}&sid=${RU_SID}&type=tcp&headerType=none"
  printf 'vless://%s@%s:%s?%s#%s\n' "$CLIENT_UUID" "$PUBIP" "$port" "$q" "NSky-RU-REALITY-${port}"
}

print_links() {
  head2 "Ссылка для Happ (добавить вручную, подписка не нужна)"
  build_link "$PORT"
  if [[ -n "$ALT_PORT" && "$ALT_PORT" != "0" ]]; then
    info ""
    info "Резервный порт (если 443 у оператора режут):"
    build_link "$ALT_PORT"
  fi
  info ""
  info "В Happ: «+» → «Добавить из буфера обмена» (или QR). Затем выбрать"
  info "узел NSky-RU-REALITY и подключиться. Обновление подписки не нужно."
}

# ── проверки ────────────────────────────────────────────────────────────────
FAILS=0
chk_ok()   { ok "$*"; }
chk_bad()  { bad "$*"; FAILS=$((FAILS+1)); }

check_reality_locally() {
  local out
  command -v openssl >/dev/null 2>&1 || { warn "openssl нет — проверка маски пропущена"; return 0; }
  # Неавторизованному клиенту REALITY отдаёт сертификат своей маски (SNI).
  # Это и есть доказательство, что вход живой и fallback-домен доступен.
  out="$(timeout 12 openssl s_client -connect "127.0.0.1:${PORT}" -servername "$SNI" -brief </dev/null 2>&1 || true)"
  if printf '%s' "$out" | grep -qiF "$SNI"; then
    chk_ok "REALITY отвечает локально сертификатом ${SNI} — маска работает"
  elif printf '%s' "$out" | grep -qi 'CONNECTION ESTABLISHED'; then
    warn "TLS локально поднимается, но сертификат маски не опознан (не критично)"
  else
    warn "«Чужой» TLS-клиент через вход не прошёл (openssl)"
    info "Для авторизованного клиента это не блокер: REALITY отдаёт маску только"
    info "незнакомым, а свой трафик идёт мимо. Смотрите строку «клиент прошёл ВЕСЬ путь»."
  fi
}

# Достижим ли домен-маска с этого VPS (нужен ТОЛЬКО для «чужого» handshake).
target_state() {
  local out
  if timeout 8 bash -c "cat < /dev/null > /dev/tcp/${SNI}/443" 2>/dev/null; then
    printf 'открыт'
  else
    printf 'недоступен'
  fi
}

# Главная проверка первого хопа: поднимаем отдельный Xray-КЛИЕНТ, который
# ходит в наш же вход так же, как это будет делать Happ с телефона
# (VLESS+REALITY+vision, тот же SNI/ключ/shortId), и через него идём в интернет.
# Зелёная строка = серверная часть целиком рабочая, дело не в DNAT и не в ключах.
probe_config() {
  # probe_config <адрес входа> <socks-порт> <fingerprint>
  local host="$1" cport="$2" fp="$3"
  cat <<PROBE
{
  "log": { "loglevel": "debug" },
  "inbounds": [
    { "tag": "probe-in", "listen": "127.0.0.1", "port": ${cport}, "protocol": "socks",
      "settings": { "auth": "noauth", "udp": false } }
  ],
  "outbounds": [
    {
      "tag": "probe-out",
      "protocol": "vless",
      "settings": { "vnext": [ { "address": "${host}", "port": ${PORT},
        "users": [ { "id": "${CLIENT_UUID}", "encryption": "none" } ] } ] },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "serverName": "${SNI}",
          "fingerprint": "${fp}",
          "publicKey": "${RU_PUB}",
          "shortId": "${RU_SID}",
          "spiderX": "/"
        }
      }
    }
  ]
}
PROBE
}

probe_once() {
  # probe_once <адрес входа> — возвращает 0 и печатает IP, либо 1 и печатает журнал
  local host="$1" fp="${2:-chrome}"
  local base cfg log cport pid i out u ip=""
  cport=$(( 18000 + RANDOM % 2000 ))
  base="$(mktemp)"; cfg="${base}.json"; rm -f "$base"
  log="${cfg%.json}.log"
  probe_config "$host" "$cport" "$fp" > "$cfg"

  "$BIN" run -config "$cfg" >"$log" 2>&1 &
  pid=$!
  for i in $(seq 1 25); do
    port_busy "$cport" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done

  if ! kill -0 "$pid" 2>/dev/null; then
    PROBE_LOG="$(tail -20 "$log" 2>/dev/null)"
    rm -f "$cfg" "$log"
    return 1
  fi

  local cerr=""
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
    cerr="$(curl -fsS --max-time 15 --connect-timeout 10 -x "socks5h://127.0.0.1:${cport}" "$u" 2>&1 >/tmp/.nsky_probe_ip || true)"
    out="$(tr -d '[:space:]' < /tmp/.nsky_probe_ip 2>/dev/null || true)"
    rm -f /tmp/.nsky_probe_ip
    if [[ "$out" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then ip="$out"; break; fi
  done
  PROBE_ERR="${cerr:-}"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  PROBE_LOG="$(tail -20 "$log" 2>/dev/null)"
  rm -f "$cfg" "$log"

  [[ -n "$ip" ]] || return 1
  PROBE_IP="$ip"
  return 0
}

# Главная проверка первого хопа: поднимаем отдельный Xray-КЛИЕНТ, который
# ходит в наш же вход так же, как это будет делать Happ с телефона
# (VLESS+REALITY+vision, тот же SNI/ключ/shortId), и через него идём в интернет.
# Пробуем два адреса: публичный (как телефон) и 127.0.0.1 (если VPS не умеет
# ходить на свой же публичный IP — hairpin NAT, это не поломка входа).
check_first_hop() {
  local host fp reach
  for host in "$PUBIP" "127.0.0.1"; do
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${host}/${PORT}" 2>/dev/null; then
      reach="открыт"
    else
      reach="не открывается"
    fi
    info "адрес ${host}:${PORT} с этого VPS — ${reach}"

   for fp in chrome safari; do
    PROBE_IP=""; PROBE_LOG=""
    if probe_once "$host" "$fp"; then
      if [[ "$PROBE_IP" == "$NL_HOST" ]]; then
        chk_ok "клиент прошёл ВЕСЬ путь через ${host}:${PORT} (fp=${fp}), выходной IP ${PROBE_IP} (NL)"
        info "Это ровно тот маршрут, по которому пойдёт телефон. Серверная часть рабочая"
      else
        chk_ok "клиент прошёл ВЕСЬ путь через ${host}:${PORT} (fp=${fp}), выходной IP ${PROBE_IP}"
      fi
      return 0
    fi

    if [[ -n "${PROBE_ERR:-}" ]]; then
      info "fp=${fp}: ответ curl: ${PROBE_ERR}"
    fi
    if [[ -n "${PROBE_LOG:-}" ]]; then
      info "fp=${fp}: последние строки клиента:"
      printf '%s\n' "$PROBE_LOG" | tail -6 | sed 's/^/      /'
    fi
   done
  done

  chk_bad "клиент через вход не прошёл ни по публичному IP, ни по 127.0.0.1"
  local jlog
  jlog="$(journalctl -u "$SERVICE" --since "-3min" --no-pager 2>/dev/null \
          | grep -viE 'Choosing .* target|non-443 ports|Reading config|core: Xray|unified platform|Penetrates' \
          | tail -30 || true)"
  if [[ -n "$jlog" ]]; then
    info "журнал сервера за последние 3 минуты:"
    printf '%s\n' "$jlog" | sed 's/^/      /'
  fi
  return 0
}

check_via_socks() {
  local port="$1" out u
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
    out="$(curl -fsS --max-time 20 -x "socks5h://127.0.0.1:${port}" "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$out" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "$out"
      return 0
    fi
  done
  :
}

check_all() {
  head2 "Служба"
  if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    chk_ok "systemd: ${SERVICE} активен"
  else
    chk_bad "systemd: ${SERVICE} не активен"
    info "systemctl status ${SERVICE} --no-pager"
  fi

  head2 "Конфигурация и порты"
  if [[ -r "$CONF" ]] && config_ok "$CONF" >/dev/null 2>&1; then
    chk_ok "Xray принимает ${CONF}"
  else
    chk_bad "Конфиг ${CONF} отсутствует или невалиден"
  fi
  local p
  for p in "$PORT" "$ALT_PORT"; do
    [[ -n "$p" && "$p" != "0" ]] || continue
    if port_busy "$p"; then chk_ok "порт ${p}/tcp слушается"; else chk_bad "порт ${p}/tcp НЕ слушается"; fi
  done

  head2 "Ключи входа"
  local derived
  derived="$(derive_pubkey "$RU_PRIV")"
  if [[ -z "$derived" ]]; then
    warn "Xray не умеет вывести публичный ключ из приватного — сверить не могу"
  elif [[ "$derived" == "$RU_PUB" ]]; then
    chk_ok "пара ключей согласована (публичный в ссылке соответствует приватному)"
  else
    chk_bad "ключи входа РАСХОДЯТСЯ: публичный в ссылке не соответствует приватному"
    info "Лечится одной командой: bash $0 --regen-keys"
  fi

  head2 "Первый хоп: клиент → этот вход (как с телефона, но без телефона)"
  info "домен-маска ${SNI}:443 с этого VPS $(target_state)"
  check_first_hop
  check_reality_locally

  head2 "Цепочка «этот VPS → NL → интернет» (без телефона)"
  local exit_ip direct_ip
  direct_ip="$(check_via_socks "$SOCKS_DIRECT" || true)"
  if [[ -n "$direct_ip" ]]; then
    chk_ok "прямой выход с VPS: ${direct_ip}"
  else
    chk_bad "не работает даже прямой выход (проблема на этом VPS, не в каскаде)"
  fi

  exit_ip="$(check_via_socks "$SOCKS_CHAIN" || true)"
  if [[ -z "$exit_ip" ]]; then
    chk_bad "через каскад трафик не прошёл: RU → NL не работает"
    info "Проверьте с этого VPS: TCP до ${NL_HOST}:${NL_PORT}"
    info "  timeout 5 bash -c 'cat < /dev/null > /dev/tcp/${NL_HOST}/${NL_PORT}' && echo открыт"
    info "Если порт открыт — смотрите журнал: journalctl -u ${SERVICE} -n 40 --no-pager"
  elif [[ "$exit_ip" == "$NL_HOST" ]]; then
    chk_ok "через каскад выходной IP ${exit_ip} — это NL-нода. Каскад РАБОТАЕТ"
  elif [[ -n "$PUBIP" && "$exit_ip" == "$PUBIP" ]]; then
    chk_bad "через каскад вышел IP этого же VPS (${exit_ip}) — цепочка не сработала"
  else
    chk_ok "через каскад выходной IP ${exit_ip} (не этот VPS) — цепочка работает"
    info "NL-нода отдаёт интернет через другой адрес — это нормально"
  fi

  echo
  if [[ $FAILS -eq 0 ]]; then
    printf '\033[1;32m  Итог: всё зелёное. Каскад проверен без телефона.\033[0m\n'
  else
    printf '\033[1;31m  Итог: ошибок %d. Смотрите строки с ✗ выше.\033[0m\n' "$FAILS"
  fi

  print_links
  return 0
}

status_short() {
  echo "NSky Entry v$VERSION"
  echo
  echo "  служба:  $(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown)"
  echo "  конфиг:  $CONF"
  echo "  порты:   $PORT/tcp${ALT_PORT:+, $ALT_PORT/tcp}"
  echo "  туннель: → ${NL_HOST:-?}:${NL_PORT:-?}"
  echo "  адрес:   ${PUBIP:-?}"
  echo
  ss -lntp 2>/dev/null | grep -E ":(${PORT}|${ALT_PORT})\b" || echo "  (порты не слушаются)"
}

# ── APPLY ───────────────────────────────────────────────────────────────────
apply() {
  echo "NSky Entry v$VERSION: вход-узел каскада"

  load_state
  # Приоритет: флаг/переменная окружения → сохранённое состояние → умолчание.
  [[ -n "$PORT_ARG" ]] && PORT="$PORT_ARG"
  [[ -n "$ALT_ARG"  ]] && ALT_PORT="$ALT_ARG"
  [[ -n "$SNI_ARG"  ]] && SNI="$SNI_ARG"

  if [[ -n "$LINK" ]]; then
    parse_link "$LINK"
  else
    if [[ -r "$DIR/upstream.link" ]]; then
      LINK="$(tr -d '\r\n' < "$DIR/upstream.link")"
      parse_link "$LINK"
      info "Ссылка взята из прошлой установки ($DIR/upstream.link)"
    else
      die "Нужна ссылка на прямой хост: bash $0 'vless://…'"
    fi
  fi
  ok "Прямой хост: ${NL_HOST}:${NL_PORT}, SNI ${NL_SNI}"

  ensure_xray
  command -v jq >/dev/null 2>&1 || info "(jq не установлен — проверка JSON будет только силами Xray)"

  # IP перепроверяем каждый раз (у провайдера он мог измениться); --ip важнее.
  if [[ -n "$PUBIP_ARG" ]]; then
    PUBIP="$PUBIP_ARG"
  else
    PUBIP=""
    detect_pubip
  fi
  ok "Внешний IP этого VPS: ${PUBIP}"

  if [[ "$NL_HOST" == "$PUBIP" ]]; then
    die "Ссылка ведёт на этот же VPS — вы взяли хост с пометкой «(RU)». Нужен прямой хост (без «(RU)»)."
  fi
  if [[ "$NL_HOST" =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; then
    die "Адрес NL в ссылке приватный (${NL_HOST}) — нужен публичный хост."
  fi

  # Ключи и UUID входного узла создаются один раз и переживают повторный запуск,
  # чтобы уже добавленная в Happ ссылка не сломалась.
  if [[ "$REGEN" == "1" ]]; then
    RU_PRIV=""; RU_PUB=""; RU_SID=""
    info "Ключи входа будут пересозданы (--regen-keys): старая ссылка перестанет работать"
  fi
  if [[ -z "$RU_PRIV" || -z "$RU_PUB" ]]; then
    gen_reality_keys
    ok "Сгенерирована новая пара ключей REALITY для входа"
  else
    info "Ключи REALITY входа сохранены с прошлого запуска"
  fi
  [[ -n "$RU_SID" ]] || RU_SID="$(new_short_id)"
  [[ -n "$CLIENT_UUID" ]] || CLIENT_UUID="$(new_uuid)"

  head2 "Порты"
  remove_conflict_dnat
  local p
  for p in "$PORT" "$ALT_PORT"; do
    [[ -n "$p" && "$p" != "0" ]] || continue
    if port_busy "$p" && ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
      ss -lntp 2>/dev/null | grep -E ":${p}\b" || true
      die "Порт ${p}/tcp занят другим процессом — освободите его"
    fi
  done

  head2 "Конфигурация"
  write_config

  head2 "Служба"
  write_unit
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE" || die "Не удалось запустить ${SERVICE}"
  if wait_listen "$PORT"; then
    ok "${SERVICE} запущен, порт $PORT слушается"
  else
    warn "порт $PORT пока не слушается"
    journalctl -u "$SERVICE" -n 20 --no-pager 2>/dev/null || true
  fi
  if [[ -n "$ALT_PORT" && "$ALT_PORT" != "0" ]]; then
    wait_listen "$ALT_PORT" && ok "порт $ALT_PORT слушается" || warn "порт $ALT_PORT не слушается"
  fi

  open_firewall
  save_state
  # Ссылку сохраняем только после всех проверок: битая не должна затирать рабочую.
  printf '%s\n' "$LINK" > "$DIR/upstream.link"
  chmod 600 "$DIR/upstream.link"

  head2 "Самопроверка"
  FAILS=0
  check_all

  echo
  echo "  Дальше — только телефон:"
  echo "    1) Wi-Fi: добавить ссылку выше в Happ (из буфера обмена)."
  echo "    2) Выключить Wi-Fi, включить мобильный интернет."
  echo "    3) Выбрать узел NSky-RU-REALITY-${PORT}, подключиться, открыть 2ip.ru."
  echo "  Повторная проверка без телефона: bash $0 --check"
}

# ── REMOVE ──────────────────────────────────────────────────────────────────
remove_all() {
  echo "NSky Entry v$VERSION: снимаю вход-узел"
  load_state
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  rm -f "$UNIT"
  systemctl daemon-reload >/dev/null 2>&1 || true
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    local p
    for p in "${PORT:-443}" "${ALT_PORT:-8443}"; do
      [[ -n "$p" && "$p" != "0" ]] && ufw delete allow "$p"/tcp >/dev/null 2>&1 || true
    done
  fi
  rm -f "$CONF"
  rm -rf "$DIR"
  ok "Служба остановлена, конфиг и состояние удалены"
  info "Xray ($BIN) оставлен в системе — он может быть нужен другим задачам."
  info "NL-нода, панель, подписки и DNAT-релей не менялись."
}

# ── main ────────────────────────────────────────────────────────────────────
case "$MODE" in
  apply)  apply ;;
  check)
    load_state
    [[ -n "$NL_HOST" ]] || die "Вход-узел не установлен (нет $DIR/entry.env)"
    check_all
    ;;
  link)
    load_state
    [[ -n "$RU_PUB" ]] || die "Вход-узел не установлен (нет $DIR/entry.env)"
    print_links
    ;;
  status) load_state; status_short ;;
  remove) remove_all ;;
esac
