#!/usr/bin/env bash
# Публикует хвост лога сборки в ветку ci-logs.
#
# Зачем: логи GitHub Actions хранятся в Azure Blob, который может быть недоступен
# из среды разработки. Ветка репозитория читается всегда, поэтому падение сборки
# разбирается по файлу отсюда.
#
# Использование: ci-log-push.sh <platform> <logfile>
set -euo pipefail

PLATFORM="${1:?нужно имя платформы}"
LOGFILE="${2:?нужен путь к логу}"

# Ограничиваем размер: в логе бывает десятки тысяч строк, нужен хвост.
if [ ! -f "$LOGFILE" ]; then
  echo "лог не найден: $LOGFILE"
  exit 0
fi
tail -c 60000 "$LOGFILE" > "ci-${PLATFORM}.log" || true

WORKDIR="$(mktemp -d)"
cp "ci-${PLATFORM}.log" "$WORKDIR/" 2>/dev/null || true

cd "$WORKDIR"
git init -q
git config user.name "ci-log-bot"
git config user.email "ci@vpnsky.local"
git checkout -q -b ci-logs
cp "ci-${PLATFORM}.log" .
git add "ci-${PLATFORM}.log"
git commit -q -m "log: ${PLATFORM} build failure (run ${GITHUB_RUN_NUMBER:-?})" || exit 0

# Токен уже есть в окружении Actions.
REMOTE="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
git push -q --force "$REMOTE" ci-logs
echo "лог опубликован в ветку ci-logs"
