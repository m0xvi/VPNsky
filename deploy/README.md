# deploy/ — заготовки развёртывания

Всё здесь — **шаблоны с плейсхолдерами**, а не готовая установка. Перед запуском:

1. `deploy/panel/.env.example` → скопировать в `.env`, заполнить секреты (`openssl rand -hex 32`).
2. `deploy/xray/profile-reality-xhttp-hysteria2.json` → заменить `__UPPER_CASE__` плейсхолдеры,
   вставить в панель как Config profile.
3. `deploy/node/docker-compose.yml` → подставить `SECRET_KEY`, выданный панелью.

## Структура

```
deploy/
├── panel/
│   ├── docker-compose.yml   # Remnawave Panel + Postgres + Valkey + Subscription page
│   └── .env.example         # шаблон секретов (реальный .env НЕ коммитить)
├── node/
│   ├── docker-compose.yml   # Remnawave Node (Xray-core)
│   └── ufw-setup.sh         # firewall: только нужные порты
└── xray/
    └── profile-reality-xhttp-hysteria2.json   # три инбаунда
```

## Проверка профиля Xray перед заливкой

```bash
# локально, если есть xray:
xray run -test -c deploy/xray/profile-reality-xhttp-hysteria2.json
```

Если `xray` нет — залить в панель и посмотреть, что панель не ругается на конфиг
(Config profiles → проверить/сохранить).

## Версии

Зафиксированы в compose-файлах:
- `remnawave/backend:3.4.8`
- `remnawave/node:3.4.4`
- `postgres:18.4`, `valkey/valkey:9-alpine`

Обновление — осознанное действие: сменить тег, перечитать changelog, снять бэкап.

## Важно про профиль Xray

В `xray/profile-reality-xhttp-hysteria2.json` первым ключом идёт блок `_comment`
(пояснения). **Перед вставкой в панель его нужно удалить** — Xray не любит лишние ключи
в корне конфигурации. JSON-валидность файла при этом сохранена.
