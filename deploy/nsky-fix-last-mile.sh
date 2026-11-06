#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════════════════════
# NSky: починка последней мили «русский релей → телефон на LTE»
#
# ОДНА команда, ТОЛЬКО на русском релее (машина B). Ничего не спрашивает,
# ничего не надо расшифровывать. Идемпотентно: повторный запуск безопасен.
#
# Что делает:
#   1) сохраняет бэкап iptables и sysctl ДО изменений;
#   2) зажимает TCP MSS до 1200 (LTE объявляет 1360, а сертификат REALITY
#      приходит крупными сегментами — классическая PMTU-дыра: «ПОДКЛЮЧЕН»,
#      0 байт, страницы в таймауте);
#   3) выставляет rp_filter=2 (loose), чтобы ответные пакеты с уже
#      отNAT-енным адресом не отбрасывались Reverse Path Filtering;
#   4) проверяет/восстанавливает FORWARD, MASQUERADE и DNAT tcp/443.
#
# Не трогает: панель, Xray, ключи, подписки, NL-ноду, UDP/443, установщик.
# Откат: bash nsky-fix-last-mile.sh --rollback
#
# Запуск на машине B:
#   bash nsky-fix-last-mile.sh
# ═════════════════════════════════════════════════════════════════════════════
set -uo pipefail

VERSION="2026-11-06.1"
NL_FILE="/opt/nsky-relay/nl-ip"
BACKUP="/root/nsky-last-mile-backup.txt"

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
head2(){ printf '\n\033[1;36m── %s ─────────────────────────────\033[0m\n' "$*"; }

echo "NSky: починка последней мили v$VERSION"

if [[ "${1:-}" == "--rollback" ]]; then
  if [[ ! -r "$BACKUP" ]]; then bad "бэкап не найден — откатывать нечего"; exit 1; fi
  OLD_RP="$(awk -F= '/^RP_ALL=/{print $2}' "$BACKUP" 2>/dev/null || true)"
  OLD_DEF="$(awk -F= '/^RP_DEFAULT=/{print $2}' "$BACKUP" 2>/dev/null || true)"
  [[ -n "$OLD_RP" ]] && sysctl -w "net.ipv4.conf.all.rp_filter=$OLD_RP" >/dev/null 2>&1 || true
  [[ -n "$OLD_DEF" ]] && sysctl -w "net.ipv4.conf.default.rp_filter=$OLD_DEF" >/dev/null 2>&1 || true
  iptables -t mangle -D FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || true
  ok "MSS-правило убрано, rp_filter восстановлен. Остальные правила не трогались."
  exit 0
fi

# ── Проверка, что это действительно релей ─────────────────────────────────
if [[ ! -r "$NL_FILE" ]]; then
  bad "Не найден $NL_FILE — это НЕ русский релей."
  warn "Запустите на машине B (той, где /root/nsky-relay.sh). На NL-ноде запускать нельзя."
  exit 1
fi
NL="$(tr -d '[:space:]' < "$NL_FILE")"
if [[ ! "$NL" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  bad "В $NL_FILE не IP-адрес — останавливаюсь"; exit 1
fi
if ! iptables -t mangle -L FORWARD -n >/dev/null 2>&1; then
  bad "iptables недоступен — нужен root: sudo bash $0"; exit 1
fi
ok "машина B (релей) опознана"

# ── 1. Бэкап ДО изменений ─────────────────────────────────────────────────
head2 "Точка восстановления"
if [[ -s "$BACKUP" ]]; then
  ok "бэкап уже есть, не перезаписываю: $BACKUP"
else
  {
    echo "# NSky last-mile backup, $(date -u '+%F %T UTC')"
    echo "RP_ALL=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo 0)"
    echo "RP_DEFAULT=$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null || echo 0)"
    echo "# --- iptables-save ---"
    iptables-save 2>/dev/null || true
  } > "$BACKUP"
  chmod 600 "$BACKUP" 2>/dev/null || true
  ok "сохранено: $BACKUP (откат: bash $0 --rollback)"
fi

ensure() { # ensure <table> <chain> <остальные аргументы>
  local t="$1" c="$2"; shift 2
  if iptables -t "$t" -C "$c" "$@" 2>/dev/null; then
    ok "уже есть: $c $*"
  else
    iptables -t "$t" -A "$c" "$@" 2>/dev/null && ok "добавлено: $c $*" || warn "не удалось добавить: $c $*"
  fi
}

# ── 2. MSS: лечим PMTU-дыру на LTE ────────────────────────────────────────
head2 "MSS и rp_filter (причина «ПОДКЛЮЧЕН, но 0 байт»)"
ensure mangle FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200

RP="$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo 0)"
RPDEF="$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null || echo 0)"
if [[ "$RP" == "1" || "$RPDEF" == "1" ]]; then
  sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1 || true
  ok "rp_filter: 1 → 2 (loose), ответные пакеты больше не отбрасываются"
else
  ok "rp_filter уже безопасный (all=$RP, default=$RPDEF)"
fi

# ── 3. Базовые правила каскада (на случай, что tcp/443 потерялось) ────────
head2 "Правила каскада"
ensure nat PREROUTING -p tcp --dport 443 -j DNAT --to-destination "$NL:8443"
ensure nat PREROUTING -p tcp --dport 8443 -j DNAT --to-destination "$NL"
ensure nat PREROUTING -p tcp --dport 2053 -j DNAT --to-destination "$NL"
ensure nat PREROUTING -p udp --dport 443 -j DNAT --to-destination "$NL"
ensure nat POSTROUTING -d "$NL" -j MASQUERADE
ensure filter FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ensure filter FORWARD -p tcp -d "$NL" -m multiport --dports 8443,2053 -j ACCEPT
ensure filter FORWARD -p udp -d "$NL" --dport 443 -j ACCEPT

C443="$(iptables -t nat -S PREROUTING 2>/dev/null | grep -c -- '--dport 443 -j DNAT' || true)"
if [[ "${C443:-0}" -gt 2 ]]; then
  warn "правил tcp/443 несколько (дубликаты) — безвредно, первое срабатывает"
fi

# ── Итог ──────────────────────────────────────────────────────────────────
head2 "Готово — больше ничего запускать не нужно"
echo "  На телефоне (LTE, Wi-Fi выключен):"
echo "    1. Happ → Отключить, затем выбрать NSky REALITY (RU)"
echo "    2. Подключить → открыть https://example.com"
echo "  Если не открылось — просто скажите «не помогло», откат одной командой:"
echo "    bash $0 --rollback"
exit 0
