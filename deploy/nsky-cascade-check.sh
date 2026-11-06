#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# NSky Cascade Check — ТОЛЬКО ЧТЕНИЕ. Ничего не меняет ни на одном сервере.
#
# Проверяет каскад «клиент → русский VPS (DNAT) → нидерландская нода»:
#   1. что в подписке реально есть хосты с пометкой (RU), что их адрес —
#      IP русского релея, а настройки (UUID, ключи, SNI, порт) совпадают
#      с прямыми хостами;
#   2. что TLS-рукопожатие до Russian-IP:8443/2053 доходит до REALITY-ноды
#      в Нидерландах (не просто «порт открыт»);
#   3. что UDP/443 (Hysteria2) возвращается на ноду через релей;
#   4. на русском VPS — все ли правила DNAT/FORWARD/MASQUERADE на месте,
#      включён ли ip_forward и жив ли systemd-юнит.
#
# Запуск:
#   На NL-сервере (панель):   bash nsky-cascade-check.sh
#   На RU-VPS (релей):        bash nsky-cascade-check.sh --relay
#
# Дополнительно:
#   --ru <IP> / --nl <IP>     явно задать адреса (иначе из state)
#   --sni <домен>             SNI REALITY (по умолчанию www.microsoft.com)
#   --state <файл>            путь до install-state.env
#   --sub-file <файл>         готовый текст подписки вместо запроса к API
#   --no-probe                не делать сетевые пробы (для офлайн-проверки)
#   --help                    справка
#
# ВНИМАНИЕ: простой «порт открыт» (/dev/tcp, nc -vz) НЕ доказывает каскад:
# пакет может принять прокси или файрвол. Поэтому здесь проверяется именно
# TLS-рукопожатие с нужным SNI и возврат UDP-пакета на ноду.
# ═══════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail

VERSION="2026-11-06.2"
STATE="/opt/nsky/install-state.env"
RELAY_STATE="/opt/nsky-relay/nl-ip"
SUB_FILE=""
NO_PROBE=0
MODE="panel"
RU_IP=""
NL_IP=""
REALITY_SNI="www.microsoft.com"
TMP=""
PASS=0
FAIL=0

ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; PASS=$(( PASS + 1 )); }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
head2(){ printf '\n\033[1;36m── %s ──────────────────────────────\033[0m\n' "$*"; }

cleanup() { if [[ -n "$TMP" && -d "$TMP" ]]; then rm -rf "$TMP"; fi; }
trap cleanup EXIT

usage() {
  cat <<'USAGE'
NSky Cascade Check (только чтение)

  bash nsky-cascade-check.sh              # на NL-сервере с панелью
  bash nsky-cascade-check.sh --relay      # на русском VPS-рееле
  bash nsky-cascade-check.sh --relay --nl <IP_нидерландского_сервера>

  --ru <IP>         IP русского релея (по умолчанию CASCADE_IP из state)
  --nl <IP>         IP нидерландской ноды (по умолчанию из /opt/nsky-relay/nl-ip)
  --sni <домен>     SNI REALITY (по умолчанию www.microsoft.com)
  --state <файл>    путь до install-state.env
  --sub-file <файл> готовый текст подписки (не запрашивать API)
  --no-probe        пропустить сетевые пробы
  --help            эта справка
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --relay)      MODE="relay"; shift ;;
    --state)      STATE="${2:-}"; shift 2 ;;
    --sub-file)   SUB_FILE="${2:-}"; shift 2 ;;
    --no-probe)   NO_PROBE=1; shift ;;
    --ru)         RU_IP="${2:-}"; shift 2 ;;
    --nl)         NL_IP="${2:-}"; shift 2 ;;
    --sni)        REALITY_SNI="${2:-}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) bad "Неизвестный аргумент: $1"; usage; exit 2 ;;
  esac
done

# awk вместо sed|head: при pipefail head закрывает трубу раньше sed.
state_get() {
  [[ -f "$STATE" ]] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$STATE"
}

urldecode() {
  local s="${1//%/\\x}"
  printf '%b' "$s"
}

printf '\033[1;36mNSky Cascade Check v%s [%s]\033[0m\n' "$VERSION" "$MODE"
info "Режим только для чтения: конфиги и правила не изменяются."

# ═══════════════════════════════════════════════════════════════════════════
# РЕЖИМ 1: русский VPS (релей)
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "relay" ]]; then
  if [[ -z "$NL_IP" && -f "$RELAY_STATE" ]]; then
    NL_IP="$(cat "$RELAY_STATE" 2>/dev/null || true)"
  fi
  if [[ -z "$NL_IP" ]]; then
    if [[ -f "$STATE" ]]; then
      warn "Похоже, --relay запущен на NL-сервере: /opt/nsky-relay/nl-ip есть только на русском VPS."
      info "Запустите чекер на русском VPS (можно с явным --nl <IP_нидерландской_ноды>)."
    fi
    bad "Не знаю IP нидерландской ноды. Укажите: --nl <IP>"
    exit 1
  fi
  info "Выходной сервер (NL): $NL_IP"

  head2 "Ядро и автозапуск"
  FW="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
  if [[ "$FW" == "1" ]]; then ok "net.ipv4.ip_forward = 1"; else bad "net.ipv4.ip_forward = $FW (релей не пересылает пакеты)"; fi
  ENABLED="$(systemctl is-enabled nsky-relay.service 2>/dev/null || true)"
  ACTIVE="$(systemctl is-active nsky-relay.service 2>/dev/null || true)"
  if [[ "$ENABLED" == "enabled" ]]; then ok "systemd: nsky-relay.service включён"; else warn "systemd: nsky-relay.service = ${ENABLED:-нет} (правила не переживут reboot)"; fi
  info "состояние юнита: ${ACTIVE:-нет}"

  head2 "Правила iptables"
  MISSING=0
  check_rule() {
    local label="$1" table="$2"; shift 2
    local rc=0
    if [[ "$table" == "nat" ]]; then
      iptables -t nat -C "$@" 2>/dev/null || rc=$?
    else
      iptables -C "$@" 2>/dev/null || rc=$?
    fi
    if [[ "$rc" -eq 0 ]]; then ok "$label"; else bad "$label — ПРАВИЛА НЕТ"; MISSING=$(( MISSING + 1 )); fi
  }
  check_rule "DNAT 8443/tcp → $NL_IP" nat PREROUTING -p tcp --dport 8443 -j DNAT --to-destination "$NL_IP"
  check_rule "DNAT 2053/tcp → $NL_IP" nat PREROUTING -p tcp --dport 2053 -j DNAT --to-destination "$NL_IP"
  check_rule "DNAT 443/udp  → $NL_IP" nat PREROUTING -p udp --dport 443 -j DNAT --to-destination "$NL_IP"
  check_rule "MASQUERADE → $NL_IP"    nat POSTROUTING -d "$NL_IP" -j MASQUERADE
  check_rule "FORWARD established"    filter FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  check_rule "FORWARD tcp 8443,2053"  filter FORWARD -p tcp -d "$NL_IP" -m multiport --dports 8443,2053 -j ACCEPT
  check_rule "FORWARD udp 443"        filter FORWARD -p udp -d "$NL_IP" --dport 443 -j ACCEPT
  check_rule "FORWARD TCPMSS clamp"   filter FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

  head2 "Счётчики (растут, когда через релей реально идут пакеты)"
  iptables -t nat -L PREROUTING -nv --line-numbers 2>/dev/null \
    | awk '/dpt:(8443|2053|443)/ || /DNAT/ { print "  " $0 }' || true
  info "POSTROUTING:"
  iptables -t nat -L POSTROUTING -nv --line-numbers 2>/dev/null \
    | awk '/MASQUERADE/ { print "  " $0 }' || true
  info "Порядок FORWARD (наши ACCEPT должны быть после цепочек ufw, но до DROP/REJECT):"
  iptables -S FORWARD 2>/dev/null | head -25 | sed 's/^/  /' || true

  head2 "Файрвол и занятые порты"
  if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | awk '/8443|2053|443|Status:/ { print "  " $0 }' || true
    POL="$(awk -F= '/^DEFAULT_FORWARD_POLICY/ { print $2 }' /etc/default/ufw 2>/dev/null || true)"
    if [[ -n "$POL" ]]; then info "DEFAULT_FORWARD_POLICY=$POL"; fi
  else
    info "ufw не установлен"
  fi
  info "Слушающие порты на релее (должно быть пусто для 8443/2053/udp443):"
  ss -lntu 2>/dev/null | awk '/:(8443|2053)/ || /:443/ { print "  " $0 }' || true

  if [[ "$NO_PROBE" -eq 0 ]]; then
    head2 "Прямая доступность ноды с релея"
    for p in 8443 2053; do
      if timeout 4 bash -c "cat < /dev/null > /dev/tcp/$NL_IP/$p" 2>/dev/null; then
        ok "$NL_IP:$p/tcp доступен"
      else
        bad "$NL_IP:$p/tcp недоступен (ufw на NL или нода не слушает)"
      fi
    done
    warn "UDP/443 с релея так не проверить — это делает обычный режим чекера на NL-сервере или телефон."
  fi

  printf '\n'
  if [[ "$FAIL" -eq 0 && "$MISSING" -eq 0 ]]; then
    ok "ИТОГ (RU): правила релея на месте. Дальше проверьте NL-сервер и телефон."
  else
    printf '\033[1;31m  ✗ ИТОГ (RU): есть проблемы. Исправьте: bash nsky-relay.sh %s\033[0m\n' "$NL_IP"
  fi
  printf '  проверок ok: %s, ошибок: %s\n\n' "$PASS" "$FAIL"
  if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# РЕЖИМ 2: NL-сервер с панелью
# ═══════════════════════════════════════════════════════════════════════════
head2 "Состояние установки"
if [[ ! -f "$STATE" ]]; then
  bad "$STATE не найден. Запустите скрипт на сервере с панелью."
  exit 1
fi
DOMAIN="$(state_get DOMAIN)"
SERVER_IP="$(state_get SERVER_IP)"
CASCADE_IP="$(state_get CASCADE_IP)"
SUB_SECRET="$(state_get SUB_SECRET)"
TEST_SUB="$(state_get TEST_SHORT_UUID)"
API_TOKEN="$(state_get API_TOKEN)"
PANEL_PORT="$(state_get PANEL_PORT)"
REALITY_SNI_STATE="$(state_get REALITY_SNI)"
[[ -n "$PANEL_PORT" ]] || PANEL_PORT=8444
[[ -n "$REALITY_SNI_STATE" ]] && REALITY_SNI="$REALITY_SNI_STATE"
[[ -n "$RU_IP" ]] || RU_IP="$CASCADE_IP"

if [[ -n "$SUB_SECRET" ]]; then ok "SUB_SECRET в state есть (ссылки не сломаются при обновлении)";
else bad "SUB_SECRET ОТСУТСТВУЕТ в state — следующий запуск установщика сменит секрет и убьёт выданные ссылки!"; fi
if [[ -n "$CASCADE_IP" ]]; then ok "Каскад прописан в state: $CASCADE_IP"; else bad "CASCADE_IP пуст — каскад не настроен (--cascade <IP>)"; fi
if [[ -n "$API_TOKEN" ]]; then ok "API-токен есть"; else warn "API-токена нет в state — подписку возьму из --sub-file, если он задан"; fi
if [[ -n "$TEST_SUB" ]]; then ok "Тестовая подписка есть"; else warn "TEST_SHORT_UUID нет — создайте пользователя в панели"; fi
info "Домен: ${DOMAIN:-нет}; IP ноды: ${SERVER_IP:-нет}; порт панели: $PANEL_PORT; SNI: $REALITY_SNI"
if [[ -z "$RU_IP" ]]; then
  bad "Не знаю IP русского релея. Укажите --ru <IP>"
  exit 1
fi
if [[ -n "$SERVER_IP" && "$RU_IP" == "$SERVER_IP" ]]; then
  bad "IP релея совпадает с IP ноды — каскад настроен неверно"
fi

head2 "Согласованность секретного пути подписки"
CADDY_SEC=""
if [[ -f /etc/caddy/Caddyfile ]]; then
  CADDY_SEC="$(grep -oP '(?<=handle /)[^/]+(?=/api/sub)' /etc/caddy/Caddyfile 2>/dev/null | head -1 || true)"
  if [[ -z "$CADDY_SEC" ]]; then
    CADDY_SEC="$(sed -n 's/.*handle \/\([^/]*\)\/api\/sub.*/\1/p' /etc/caddy/Caddyfile 2>/dev/null | head -1 || true)"
  fi
fi
PANEL_SEC=""
PANEL_ENV="/opt/nsky/panel/.env"
if [[ -f "$PANEL_ENV" ]]; then
  SPD="$(awk -F= '/^SUB_PUBLIC_DOMAIN=/ { print substr($0, length("SUB_PUBLIC_DOMAIN=") + 1); exit }' "$PANEL_ENV")"
  PANEL_SEC="${SPD#*/}"
  PANEL_SEC="${PANEL_SEC%%/*}"
fi
if [[ -n "$CADDY_SEC" && -n "$PANEL_SEC" ]]; then
  if [[ "$CADDY_SEC" == "$PANEL_SEC" ]]; then
    ok "Caddy и панель используют один секретный сегмент"
  else
    bad "сегмент в Caddyfile и в SUB_PUBLIC_DOMAIN панели РАСХОДИТСЯ — часть ссылок будет 404"
  fi
else
  warn "не удалось сравнить секрет: не найден сегмент в Caddyfile и/или SUB_PUBLIC_DOMAIN в .env панели"
fi
if [[ -n "$SUB_SECRET" && -n "$CADDY_SEC" ]]; then
  if [[ "$SUB_SECRET" == "$CADDY_SEC" ]]; then
    ok "SUB_SECRET в state совпадает с Caddyfile"
  else
    bad "SUB_SECRET в state не совпадает с Caddyfile — ссылка из state и ссылка из панели разные"
  fi
else
  info "сверка с state пропущена: SUB_SECRET отсутствует (см. раздел 1 инструкции)"
fi

TMP="$(mktemp -d)"
chmod 700 "$TMP"
SUB="$TMP/sub.txt"

head2 "Подписка: что реально отдаёт панель"
if [[ -n "$SUB_FILE" ]]; then
  cp "$SUB_FILE" "$SUB"
  info "Взят файл: $SUB_FILE"
elif [[ -n "$TEST_SUB" ]]; then
  SUB_RAW="$(curl -sS --max-time 20 \
    -H 'x-forwarded-for: 127.0.0.1' -H 'x-forwarded-proto: https' \
    "http://127.0.0.1:3000/api/sub/$TEST_SUB" 2>/dev/null || true)"
  SUB_TEXT="$SUB_RAW"
  case "$SUB_RAW" in
    *"://"*) : ;;
    *) SUB_TEXT="$(printf '%s' "$SUB_RAW" | base64 -d 2>/dev/null || true)" ;;
  esac
  printf '%s\n' "$SUB_TEXT" > "$SUB"
  chmod 600 "$SUB"
else
  : > "$SUB"
fi

if [[ ! -s "$SUB" ]]; then
  bad "Подписка пустая или недоступна. Панель → Hosts / Internal Squads; лог: docker logs remnawave"
else
  declare -A H_ADDR H_PORT H_SNI H_BASE H_PROTO
  LINKS=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || continue
    case "$line" in \#*) continue ;; esac
    # Берём только строки-ссылки: в ответе панели может оказаться HTML/JSON.
    case "$line" in
      vless://*|hysteria2://*|trojan://*|ss://*|hy2://*) : ;;
      *) continue ;;
    esac
    proto="${line%%://*}"
    rest="${line#*://}"
    auth="${rest%%[/?#]*}"
    userinfo=""
    case "$auth" in *"@"*) userinfo="${auth%@*}" ;; esac
    hostport="${auth##*@}"
    host="${hostport%%:*}"
    port=""
    case "$hostport" in *:*) port="${hostport##*:}" ;; esac
    tail="${rest#"$auth"}"
    qpart="${tail%%#*}"
    qpart="${qpart#\?}"
    remark=""
    case "$line" in *"#"*) remark="$(urldecode "${line##*#}")" ;; esac
    sni=""
    case "$qpart" in *sni=*) sni="${qpart#*sni=}"; sni="${sni%%&*}"; sni="$(urldecode "$sni")" ;; esac
    base="${proto}://${userinfo}@ADDR:${port}?${qpart}"
    if [[ -n "$remark" ]]; then
      H_ADDR["$remark"]="$host"
      H_PORT["$remark"]="$port"
      H_SNI["$remark"]="$sni"
      H_BASE["$remark"]="$base"
      H_PROTO["$remark"]="$proto"
      LINKS=$(( LINKS + 1 ))
      info "$(printf '%-24s' "$remark") ${proto}://${host}:${port}  sni=${sni:-—}"
    fi
  done < "$SUB"

  if [[ "$LINKS" -eq 0 ]]; then
    bad "В подписке нет ни одной ссылки с названием сервера"
  fi

  check_pair() {
    local direct="$1" ru="$2" want_port="$3" want_sni="$4"
    local d="${H_ADDR[$direct]:-}" r="${H_ADDR[$ru]:-}"
    if [[ -z "$d" ]]; then bad "нет прямого хоста «$direct»"; return 0; fi
    if [[ -z "$r" ]]; then bad "НЕТ КАСКАДНОГО ХОСТА «$ru» — в подписке только прямые серверы"; return 0; fi
    if [[ "$r" == "$RU_IP" ]]; then ok "«$ru» → $RU_IP"; else bad "«$ru» ведёт на $r, а должен на $RU_IP"; fi
    if [[ "$d" == "$SERVER_IP" ]]; then ok "«$direct» → $SERVER_IP"; else warn "«$direct» ведёт на $d (ожидался $SERVER_IP) — сверьте вручную"; fi
    if [[ "${H_PORT[$ru]:-}" == "$want_port" && "${H_PORT[$direct]:-}" == "$want_port" ]]; then
      ok "порт $want_port у обеих записей"
    else
      bad "порт не совпал: прямой=${H_PORT[$direct]:-?}, RU=${H_PORT[$ru]:-?}, нужно $want_port"
    fi
    if [[ "${H_SNI[$ru]:-}" == "$want_sni" ]]; then ok "SNI у (RU) = $want_sni"; else bad "SNI у (RU) = ${H_SNI[$ru]:-пусто}, нужно $want_sni"; fi
    if [[ "${H_BASE[$ru]:-}" == "${H_BASE[$direct]:-}" ]]; then
      ok "настройки инбаунда одинаковые (UUID/ключи/параметры), меняется только адрес"
    else
      bad "«$ru» и «$direct» отличаются не только адресом — хосты привязаны к разным инбаундам"
    fi
  }
  check_pair "NSky REALITY"   "NSky REALITY (RU)"   8443 "$REALITY_SNI"
  check_pair "NSky XHTTP"     "NSky XHTTP (RU)"     2053 "$REALITY_SNI"
  HY2_EXPECTED=0
  if [[ -n "${H_ADDR["NSky Hysteria2"]:-}" ]]; then HY2_EXPECTED=1; fi
  if [[ "$HY2_EXPECTED" -eq 1 ]]; then
    check_pair "NSky Hysteria2" "NSky Hysteria2 (RU)" 443 "$DOMAIN"
  else
    info "Hysteria2 в подписке нет (сертификат ещё не выпущен) — это не ошибка, проверяем 4 ссылки."
  fi
  WANT=$(( 4 + 2 * HY2_EXPECTED ))
  if [[ "$LINKS" -eq "$WANT" ]]; then ok "ссылок в подписке: $LINKS (ожидалось $WANT)";
  else warn "ссылок в подписке: $LINKS, ожидалось $WANT — возможно, лишние/чужие хосты"; fi
fi

if [[ "$NO_PROBE" -eq 0 ]]; then
  head2 "Публичная ссылка и порты на NL-ноде"
  if [[ -n "$SUB_SECRET" && -n "$TEST_SUB" && -n "$DOMAIN" ]]; then
    PUBLIC_URL="https://$DOMAIN/$SUB_SECRET/api/sub/$TEST_SUB"
    CODE="$(curl -sS --max-time 12 -o /dev/null -w '%{http_code}' \
      -H 'User-Agent: Happ/1.0' "$PUBLIC_URL" 2>/dev/null || echo 000)"
    if [[ "$CODE" != "000" && "$CODE" != "404" ]]; then
      ok "публичная ссылка отвечает (HTTP $CODE) — секретный путь Caddy работает"
    else
      bad "публичная ссылка не отвечает (HTTP $CODE); проверьте Caddyfile и SUB_SECRET"
    fi
  else
    warn "проверка публичной ссылки пропущена: нет SUB_SECRET в state (исправьте по разделу 1 инструкции)"
  fi
  info "Слушающие порты:"
  ss -lntu 2>/dev/null | awk 'NR==1 || /:(8443|8444|2053)/ || /:443/ { print "  " $0 }' | head -20 || true
  if command -v ufw >/dev/null 2>&1; then
    info "ufw (нужны 8443/tcp, 2053/tcp, 443/udp, 443/tcp):"
    ufw status 2>/dev/null | awk '/8443|2053|443\/udp|443\/tcp/ { print "  " $0 }' || true
  fi

  head2 "Сквозной путь: TLS до REALITY через русский IP"
  # Обычный TCP-connect здесь недостаточен: пакет может принять прокси/файрвол.
  # Шлём ClientHello с нужным SNI на RU_IP:8443/2053. Если DNAT работает,
  # рукопожатие примет REALITY-инбаунд NL-ноды (и подставит сертификат target'а).
  tls_subject() {
    local host="$1" port="$2"
    timeout 10 openssl s_client -connect "$host:$port" \
      -servername "$REALITY_SNI" -showcerts </dev/null 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null || true
  }
  tls_probe() {
    local port="$1" label="$2"
    if command -v openssl >/dev/null 2>&1; then
      local subject="" direct=""
      subject="$(tls_subject "$RU_IP" "$port")"
      if [[ -n "$subject" ]]; then
        ok "$label: TLS-рукопожатие дошло до ноды ($subject)"
        return 0
      fi
      # Контрольный замер: тот же запрос напрямую в локальный Xray.
      # Если и там пусто — дело в target REALITY, а не в каскаде.
      direct="$(tls_subject "127.0.0.1" "$port")"
      if [[ -n "$direct" ]]; then
        bad "$label: напрямую TLS есть, через $RU_IP — нет → не работает DNAT/форвард/ufw"
      else
        warn "$label: TLS нет ни через релей, ни напрямую — проверьте доступность target $REALITY_SNI:443 с ноды; каскад этим тестом не подтверждён"
      fi
    else
      if timeout 4 bash -c "cat < /dev/null > /dev/tcp/$RU_IP/$port" 2>/dev/null; then
        warn "$label: TCP есть, но openssl не найден — проверка слабая"
      else
        bad "$label: $RU_IP:$port недоступен"
      fi
    fi
  }
  tls_probe 8443 "REALITY (RU)"
  tls_probe 2053 "XHTTP (RU)"

  head2 "Сквозной путь: UDP/443 (Hysteria2)"
  if command -v tcpdump >/dev/null 2>&1; then
    CAP="$TMP/udp.cap"
    # Шлём UDP на RU_IP:443. Релей DNAT'ит его обратно на NL:443, и пакет
    # приходит уже с src=RU_IP — это и ловим. Исходящий пакет под фильтр не
    # попадает (у него src=IP ноды).
    timeout 8 tcpdump -ni any -c 1 "udp and src host $RU_IP and dst port 443" \
      > "$CAP" 2>/dev/null &
    CAP_PID=$!
    sleep 1
    for _i in 1 2 3 4 5; do
      timeout 1 bash -c "printf 'nsky-probe' > /dev/udp/$RU_IP/443" 2>/dev/null || true
      sleep 0.2
    done
    wait "$CAP_PID" 2>/dev/null || true
    if [[ -s "$CAP" ]]; then
      ok "UDP/443 вернулся на NL-ноду через релей: $(head -1 "$CAP")"
    else
      bad "UDP/443 не дошёл — проверьте ufw на обоих VPS и DNAT 443/udp"
    fi
  else
    warn "tcpdump не установлен — UDP/443 не проверен. Проверьте Hysteria2 (RU) телефоном."
  fi
fi

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
  if [[ "$NO_PROBE" -eq 1 ]]; then
    ok "ИТОГ (NL): конфигурация подписки верная; путь трафика НЕ проверялся (--no-probe)."
  else
    ok "ИТОГ (NL): каскад по конфигурации и по пути трафика выглядит рабочим."
  fi
  info "Осталась главная проверка — телефон в сети Билайн (не Wi-Fi), сервер с пометкой (RU)."
else
  printf '\033[1;31m  ✗ ИТОГ (NL): найдено проблем: %s (см. строки ✗ выше).\033[0m\n' "$FAIL"
  info "Если все проверки подписки, TLS и UDP отмечены ✓ — сам каскад работает,"
  info "а оставшиеся ✗ относятся к оформлению/секретам и на连接方式 не влияют."
fi
printf '  проверок ok: %s, ошибок: %s\n\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
exit 0
