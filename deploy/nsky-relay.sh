#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# NSky Relay — релей на русском VPS для обхода мобильных блокировок.
#
# Архитектура каскада:
#   сотрудник (мобильная сеть РФ)
#     → русский VPS (этот скрипт: проброс портов на уровне ядра)
#       → нидерландский сервер NSky (Xray, exit-нода)
#         → интернет (выход в Нидерландах)
#
# Русский VPS ничего не расшифровывает: клиентский TLS (REALITY) идёт
# до нидерландской ноды целиком. Релей работает как обычный NAT —
# ни одного нового слушающего сервиса, сканеру здесь нечего искать.
#
# Пробрасываются порты туннелей (совпадают с nsky-install.sh):
#   8443/tcp (REALITY), 2053/tcp (XHTTP), 443/udp (Hysteria2)
# Порт панели и подписка через релей НЕ идут.
#
# Использование:
#   bash nsky-relay.sh <IP_нидерландского_сервера>   # включить каскад
#   bash nsky-relay.sh --status                      # состояние релея
#   bash nsky-relay.sh --remove                      # выключить каскад
#
# Идемпотентен: повторный запуск ничего не ломает и не дублирует.
# SSH (порт 22) и INPUT-цепочка не затрагиваются.
# ═══════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail

NSKY_RELAY_VERSION="2026-11-06.1"
DIR="/opt/nsky-relay"
NL_IP=""
MODE="apply"
for arg in "$@"; do
  case "$arg" in
    --remove) MODE="remove" ;;
    --status) MODE="status" ;;
    *) [[ -z "$NL_IP" ]] && NL_IP="$arg" ;;
  esac
done

ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; }
die()  { bad "$*"; exit 1; }

# ── режимы без аргумента: IP берём из сохранённого состояния ────────────────
if [[ -z "$NL_IP" ]]; then
  [[ -f "$DIR/nl-ip" ]] || die "Использование: bash $0 <IP_нидерландского_сервера>  (или --status / --remove)"
  NL_IP="$(cat "$DIR/nl-ip")"
fi
[[ "$NL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Не похоже на IPv4: $NL_IP"

[[ $EUID -eq 0 ]] || die "Запускать от root"

# ── служебные ───────────────────────────────────────────────────────────────
ensure_rule() {
  # ensure_rule [nat] <цепочка> <правило...>: добавляет только если правила нет.
  local t=""
  if [[ "${1:-}" == "nat" ]]; then t="-t nat"; shift; fi
  if iptables $t -C "$@" 2>/dev/null; then return 0; fi
  iptables $t -A "$@"
}
delete_rule() {
  local t=""
  if [[ "${1:-}" == "nat" ]]; then t="-t nat"; shift; fi
  iptables $t -D "$@" 2>/dev/null || true
}

# ── STATUS ──────────────────────────────────────────────────────────────────
if [[ "$MODE" == "status" ]]; then
  echo "NSky Relay v$NSKY_RELAY_VERSION → $NL_IP"
  echo
  echo "── Проброс портов (nat/PREROUTING) ──"
  iptables -t nat -L PREROUTING -nv --line-numbers 2>/dev/null | grep -E "dpt:(8443|2053)|dpt:443|DNAT" || echo "  (нет правил — релей не установлен)"
  echo
  echo "── Обратный трафик (nat/POSTROUTING) ──"
  iptables -t nat -L POSTROUTING -nv --line-numbers 2>/dev/null | grep -E "$NL_IP|MASQ" | head -3 || echo "  (нет)"
  echo
  echo "── Доступность выходного сервера ──"
  if timeout 4 bash -c "cat < /dev/null > /dev/tcp/$NL_IP/8443" 2>/dev/null; then
    ok "$NL_IP:8443 (REALITY) доступен"
  else
    warn "$NL_IP:8443 недоступен с этого VPS"
  fi
  if timeout 4 bash -c "cat < /dev/null > /dev/tcp/$NL_IP/2053" 2>/dev/null; then
    ok "$NL_IP:2053 (XHTTP) доступен"
  else
    warn "$NL_IP:2053 недоступен"
  fi
  exit 0
fi

# ── REMOVE ──────────────────────────────────────────────────────────────────
if [[ "$MODE" == "remove" ]]; then
  delete_rule nat PREROUTING -p tcp --dport 8443 -j DNAT --to-destination "$NL_IP"
  delete_rule nat PREROUTING -p tcp --dport 2053 -j DNAT --to-destination "$NL_IP"
  delete_rule nat PREROUTING -p udp --dport 443 -j DNAT --to-destination "$NL_IP"
  delete_rule nat POSTROUTING -d "$NL_IP" -j MASQUERADE
  delete_rule FORWARD -p tcp -d "$NL_IP" -m multiport --dports 8443,2053 -j ACCEPT
  delete_rule FORWARD -p udp -d "$NL_IP" --dport 443 -j ACCEPT
  delete_rule FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  delete_rule FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  systemctl disable --now nsky-relay.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/nsky-relay.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$DIR"
  ok "Каскад выключен, правила удалены"
  info "IP-форвардинг оставлен включённым (безопасно, работает и для других задач)"
  exit 0
fi

# ── APPLY ───────────────────────────────────────────────────────────────────
echo "NSky Relay v$NSKY_RELAY_VERSION: релей → $NL_IP"

command -v iptables >/dev/null 2>&1 || {
  info "Ставлю iptables…"
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq iptables >/dev/null 2>&1
}
command -v iptables >/dev/null 2>&1 || die "iptables не установлен"

# На релее порты должны быть свободны: если что-то уже слушает — предупредим.
BUSY=""
ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ':(8443|2053)$' && BUSY="8443/2053(tcp)"
[[ -z "$BUSY" ]] || die "Порт $BUSY уже занят на этом VPS — релей конфликтует. Освободите порт."

# 1. Форвардинг пакетов — сердце релея.
cat > /etc/sysctl.d/99-nsky-relay.conf <<SYSCTL
# NSky Relay: пересылка VPN-пакетов на выходной сервер
net.ipv4.ip_forward = 1
SYSCTL
sysctl --system >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null
ok "IP-форвардинг включён"

# 2. Правила (сам скрипт правил идемпотентен — его же дергает systemd при загрузке).
mkdir -p "$DIR"
cat > "$DIR/apply.sh" <<APPLY
#!/usr/bin/env bash
# Правила NSky Relay. Генерируется nsky-relay.sh, руками можно не трогать.
set -euo pipefail
NL_IP="$NL_IP"
ensure_rule() {
  local t=""
  if [[ "\${1:-}" == "nat" ]]; then t="-t nat"; shift; fi
  if iptables \$t -C "\$@" 2>/dev/null; then return 0; fi
  iptables \$t -A "\$@"
}
sysctl -w net.ipv4.ip_forward=1 >/dev/null
# VPN-порты: клиент → русский VPS → нидерландская нода
ensure_rule nat PREROUTING -p tcp --dport 8443 -j DNAT --to-destination \$NL_IP
ensure_rule nat PREROUTING -p tcp --dport 2053 -j DNAT --to-destination \$NL_IP
ensure_rule nat PREROUTING -p udp --dport 443 -j DNAT --to-destination \$NL_IP
# Обратный трафик: ответы ноды должны возвращаться через этот VPS
ensure_rule nat POSTROUTING -d \$NL_IP -j MASQUERADE
# Форвард: уже установленные соединения + новые к портам туннелей
ensure_rule FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ensure_rule FORWARD -p tcp -d \$NL_IP -m multiport --dports 8443,2053 -j ACCEPT
ensure_rule FORWARD -p udp -d \$NL_IP --dport 443 -j ACCEPT
# Защита от экзотических MTU на пути клиент→релей→нода
ensure_rule FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
# UDP-сессии QUIC (Hysteria2) не должны рваться по таймауту conntrack
sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream=120 >/dev/null 2>&1 || true
APPLY
chmod +x "$DIR/apply.sh"
bash "$DIR/apply.sh"
ok "Правила проброса установлены (8443/tcp, 2053/tcp, 443/udp → $NL_IP)"

# 3. Файрвол русского VPS: если активен ufw — открываем только нужное.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 8443/tcp >/dev/null
  ufw allow 2053/tcp >/dev/null
  ufw allow 443/udp >/dev/null
  ok "ufw: открыты 8443/tcp, 2053/tcp, 443/udp (SSH не тронут)"
fi

# 4. Автозапуск правил после перезагрузки VPS.
cat > /etc/systemd/system/nsky-relay.service <<UNIT
[Unit]
Description=NSky Relay: DNAT VPN ports to NL exit
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$DIR/apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable nsky-relay.service >/dev/null 2>&1 || true
ok "Правила переживут перезагрузку (systemd: nsky-relay)"

echo "$NL_IP" > "$DIR/nl-ip"
chmod 600 "$DIR/nl-ip"

# 5. Проверка доступности выходного сервера.
echo
if timeout 4 bash -c "cat < /dev/null > /dev/tcp/$NL_IP/8443" 2>/dev/null; then
  ok "Выходной сервер отвечает: $NL_IP:8443"
else
  warn "$NL_IP:8443 не отвечает. Проверь: пинг с этого VPS и ufw на выходном сервере."
fi

echo
echo "  Каскад включён. Дальше на панельном сервере (Нидерланды):"
echo "    bash nsky-install.sh <домен> <email> --cascade $(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)"
echo "  Это добавит в подписку серверы с пометкой (RU) — их выбирают"
echo "  сотрудники с мобильных сетей. Проверка состояния: bash $0 --status"
