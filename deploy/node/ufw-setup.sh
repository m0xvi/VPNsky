# Firewall (UFW) для ноды Remnawave
# Применить: sudo bash deploy/node/ufw-setup.sh
#
# Открываем только то, что реально нужно:
#   2222/tcp — управление нодой со стороны панели (лучше ограничить IP панели)
#   443/tcp  — VLESS REALITY
#   8443/tcp — VLESS XHTTP
#   443/udp  — Hysteria2
#   22/tcp   — SSH (лучше сменить порт и/или ограничить по IP)
#
# ВАЖНО: если 443/udp занять нельзя (провайдер/роутинг), Hysteria2 переносится на другой порт.

set -euo pipefail

PANEL_IP="${PANEL_IP:-}"   # IP панели; если задан — 2222 открывается только для него
SSH_PORT="${SSH_PORT:-22}"

echo "==> Настройка UFW"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow "${SSH_PORT}"/tcp comment 'ssh'
ufw allow 443/tcp  comment 'vless-reality'
ufw allow 8443/tcp comment 'vless-xhttp'
ufw allow 443/udp  comment 'hysteria2'

if [ -n "${PANEL_IP}" ]; then
  ufw allow from "${PANEL_IP}" to any port 2222 proto tcp comment 'remnawave-node-api'
else
  echo "!! PANEL_IP не задан — порт 2222 будет открыт всем. Задайте PANEL_IP=..."
  ufw allow 2222/tcp comment 'remnawave-node-api'
fi

ufw --force enable
ufw status verbose
