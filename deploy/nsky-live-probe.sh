#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# NSky Live Probe — ТОЛЬКО ЧТЕНИЕ. Ничего не меняет ни на одном сервере.
#
# Зачем: чекер подтверждает конфигурацию, но не отвечает на вопрос «почему
# телефон подключён, а страница не открывается». Этот скрипт смотрит на ЖИВОЙ
# трафик в момент подключения телефона и даёт один из трёх вердиктов:
#
#   A) нода НЕ отвечает на ClientHello  → проблема в Xray/REALITY (ключи, inbound)
#   B) нода отвечает, но ответ не уходит → обратный путь через релей / DPI
#   C) пакеты вообще не доходят         → телефон не подключался или не тот сервер
#
# Дополнительно сверяет pbk/sid из выдаваемой подписки с ключами в state,
# НЕ печатая сами значения.
#
# Запуск (на NL-сервере с панелью, из-под root):
#   bash nsky-live-probe.sh            # ждёт 15 секунд, за это время нажмите
#                                      # «Подключить» на телефоне
#   bash nsky-live-probe.sh --no-wait  # не ждать (если телефон уже подключён)
#   bash nsky-live-probe.sh --help
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

VERSION="2026-11-06.2"
STATE="${NSKY_STATE:-/opt/nsky/install-state.env}"
WAIT=15
HINT=1

for arg in "$@"; do
  case "$arg" in
    --no-wait) WAIT=5; HINT=0 ;;
    --help|-h)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Неизвестный аргумент: $arg (см. --help)" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
head2(){ printf '\n\033[1;36m── %s ─────────────────────────────\033[0m\n' "$*"; }
urldecode() { printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')"; }
state_get() { awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$STATE" 2>/dev/null; }

echo "NSky Live Probe v$VERSION [только чтение]"

if [[ ! -r "$STATE" ]]; then
  bad "$STATE не найден — запустите на NL-сервере с панелью"
  exit 1
fi

RU="$(state_get CASCADE_IP)"
NL="$(state_get SERVER_IP)"
PUB="$(state_get REALITY_PUB)"
SID="$(state_get REALITY_SHORT_ID)"
SHORT="$(state_get TEST_SHORT_UUID)"
SECRET="$(state_get SUB_SECRET)"

if [[ -z "$RU" || -z "$NL" ]]; then
  bad "В state нет CASCADE_IP или SERVER_IP"
  exit 1
fi

# ── 1. Согласованность ключей REALITY ──────────────────────────────────────
head2 "Ключи REALITY: подписка против живого профиля панели (значения не печатаются)"
KEYS_OK=1
if [[ -z "$PUB" || -z "$SID" ]]; then
  warn "В state нет REALITY_PUB / REALITY_SHORT_ID — сверку пропускаю"
elif [[ -z "$SHORT" ]]; then
  warn "В state нет TEST_SHORT_UUID — сверку пропускаю"
else
  RAW="$(curl -sS --max-time 10 \
    -H 'x-forwarded-for: 127.0.0.1' -H 'x-forwarded-proto: https' \
    -H 'User-Agent: Happ/1.0' "http://127.0.0.1:3000/api/sub/$SHORT" 2>/dev/null || true)"
  TXT="$RAW"
  case "$RAW" in
    *"://"*) : ;;
    *) TXT="$(printf '%s' "$RAW" | base64 -d 2>/dev/null || true)" ;;
  esac
  if [[ -z "$TXT" ]]; then
    warn "Подписку получить не удалось — сверку пропускаю"
  else
    LINE="$(printf '%s\n' "$TXT" | grep -m1 'vless://' | cut -d'#' -f1 || true)"
    if [[ -z "$LINE" ]]; then
      warn "В подписке нет vless-ссылки — сверку пропускаю"
    else
      GOT_PUB="$(urldecode "$(printf '%s' "$LINE" | sed -n 's/.*[?&]pbk=\([^&]*\).*/\1/p')")"
      GOT_SID="$(urldecode "$(printf '%s' "$LINE" | sed -n 's/.*[?&]sid=\([^&]*\).*/\1/p')")"
      # ИСТОЧНИК ИСТИНЫ — живой конфиг-профиль панели, а не файл state.
      P_SID=""; P_PRIV=""
      TOKEN="$(state_get API_TOKEN)"
      if [[ -n "$TOKEN" ]] && command -v jq >/dev/null 2>&1; then
        PROF="$(curl -sS --max-time 10 -H 'X-Remnawave-Client-Type: browser' \
          -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:3000/api/config-profiles" 2>/dev/null || true)"
        # config может быть объектом ИЛИ строкой JSON — пробуем оба варианта.
        for JQF in '.' '(.response.configProfiles[0].config | fromjson?)'; do
          P_SID="$(printf '%s' "$PROF" | jq -r "$JQF | [.. | objects | .streamSettings? // empty | .realitySettings? // empty | .shortIds? // empty | arrays | .[]] | .[0] // empty" 2>/dev/null || true)"
          P_PRIV="$(printf '%s' "$PROF" | jq -r "$JQF | [.. | objects | .streamSettings? // empty | .realitySettings? // empty | .privateKey? // empty | scalars] | .[0] // empty" 2>/dev/null || true)"
          [[ -n "$P_SID" ]] && break
        done
      fi
      if [[ -n "$P_SID" ]]; then
        if [[ "$GOT_SID" == "$P_SID" ]]; then ok "shortId подписки == shortIds профиля панели (нода и клиент согласованы)"; else bad "РАСХОЖДЕНИЕ shortId: подписка != конфиг-профиль панели"; KEYS_OK=0; fi
        if [[ "$SID" != "$P_SID" ]]; then warn "файл state хранит другой shortId — это устаревшая записка, нода её не читает (не причина)"; else ok "state совпадает с профилем"; fi
      else
        warn "Профиль панели прочитать не удалось — сравниваю только со state (справочно)"
        if [[ "$GOT_SID" == "$SID" ]]; then ok "shortId подписки совпадает с state (справочно)"; else warn "shortId подписки != state: state мог устареть, это НЕ доказательство поломки"; fi
      fi
      if [[ -n "$P_PRIV" ]]; then
        SP="$(state_get REALITY_PRIV)"
        if [[ "$P_PRIV" == "$SP" ]]; then ok "приватный ключ профиля == state"; else warn "приватный ключ в профиле отличается от state (проверьте pbk в подписке)"; fi
      fi
      if [[ "$GOT_PUB" == "$PUB" ]]; then ok "публичный ключ подписки совпадает с state"; else warn "публичный ключ подписки != state (сверяйте с профилем панели)"; fi
    fi
  fi
fi
if [[ "$KEYS_OK" == "0" ]]; then
  warn "Расхождение с ЖИВЫМ профилем — реальная причина срыва REALITY."
  warn "Правится в панели: Management → Config Profiles → inbound REALITY → shortIds."
  warn "НЕ запускайте установщик: он перегенерирует все ключи и убьёт выданные ссылки."
fi

# ── 2. Живой трафик ────────────────────────────────────────────────────────
head2 "Живой TCP-трафик между релеем и нодой"
if ! command -v tcpdump >/dev/null 2>&1; then
  warn "tcpdump не найден — пропускаю замер"
else
  CAP="$(mktemp)"
  chmod 600 "$CAP"
  FILTER="tcp and host $RU and (port 8443 or port 2053)"
  if [[ "$HINT" -eq 1 ]]; then
    info "Слушаю $WAIT секунд. СЕЙЧАС нажмите «Подключить» на телефоне (LTE, сервер (RU))."
  else
    info "Слушаю $WAIT секунд уже установленное соединение."
  fi
  timeout "$((WAIT + 3))" tcpdump -l -ni eth0 "$FILTER" > "$CAP" 2>/dev/null || true

  # Входящие: источник — релей. Исходящие: источник — нода, получатель — релей.
  IN="$(grep -c "IP $RU\." "$CAP" 2>/dev/null || true)"
  OUT="$(grep -cE "IP $NL\.[0-9]+ > $RU\." "$CAP" 2>/dev/null || true)"
  BIG="$(grep -E "IP $NL\.[0-9]+ > $RU\." "$CAP" 2>/dev/null | grep -cE 'length [1-9][0-9]*' || true)"
  IN="${IN:-0}"; OUT="${OUT:-0}"; BIG="${BIG:-0}"
  info "пакетов от релея к ноде: $IN; ответов от ноды к релею: $OUT; из них с данными: $BIG"
  if [[ "$IN" -gt 0 ]]; then
    MAXLEN="$(grep -oE 'length [0-9]+' "$CAP" 2>/dev/null | awk '{print $2}' | sort -n | tail -1 || true)"
    info "максимальный размер пакета в замере: ${MAXLEN:-0} байт (MSS на LTE обычно 1360)"
  fi
  rm -f "$CAP"

  if [[ "$IN" -eq 0 ]]; then
    warn "Вердикт C: за эти $WAIT секунд пакеты не пришли. Телефон не нажимал «Подключить», выбран не (RU)-сервер или соединение уже было установлено раньше."
    info "Повторите: отключите Happ, запустите скрипт и сразу нажмите «Подключить»."
  elif [[ "$OUT" -eq 0 ]]; then
    bad "Вердикт A: нода получила пакеты (в т.ч. ClientHello) и НЕ ОТВЕТИЛА."
    warn "Проблема в Xray/REALITY на NL: смотрите логи ниже и сверку ключей выше."
  elif [[ "$BIG" -eq 0 ]]; then
    warn "Вердикт B1: нода отвечает только пустыми ACK без данных."
    warn "ServerHello/сертификат не уходит: возможны расхождение ключей REALITY, недоступный target или обрезка больших пакетов по MTU (MSS 1360)."
  else
    ok "Вердикт B: нода отвечает, в т.ч. пакетами с данными. TCP в обе стороны идёт."
    warn "Если страница всё равно не открывается — ответ не доходит до телефона: обратный DNAT/MASQUERADE на релее или DPI на обратном направлении."
  fi
fi

# ── 3. Логи ноды ───────────────────────────────────────────────────────────
head2 "Последние ошибки ноды (только строки с ошибками)"
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
  LOGS="$(docker logs --tail 200 remnanode 2>&1 | tr -cd '\11\12\15\40-\176' | grep -aiE 'reality|invalid|error|fail|reject|timeout|handshake|shortId|fallback' | tail -12 || true)"
  if [[ -z "$LOGS" ]]; then ok "в последних 200 строках ошибок нет"; else printf '%s\n' "$LOGS" | sed 's/^/    /'; fi
else
  warn "контейнер remnanode не найден"
fi

# 4. Доступность target REALITY с NL-ноды: если target молчит, Xray не отвечает клиенту.
head2 "Доступность target REALITY с NL-ноды"
SNI="$(state_get REALITY_SNI)"
if [[ -z "$SNI" ]]; then
  warn "REALITY_SNI не найден в state"
elif curl -sS --max-time 6 -o /dev/null "https://$SNI/" 2>/dev/null; then
  ok "target REALITY доступен с NL-ноды"
else
  bad "target REALITY НЕдоступен с NL-ноды — Xray не сможет ответить ни валидному, ни чужому клиенту"
  warn "Проверьте исходящий https с ноды и смените target в конфиг-профиле на доступный сайт."
fi

head2 "Что прислать"
info "Четыре строки: вердикт, согласованность shortId с профилем, доступность target, ошибки из лога."
info "Без доменов, IP, паролей и ссылок — скрипт их и не печатает."
exit 0
