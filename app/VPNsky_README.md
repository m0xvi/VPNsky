# VPNsky Client

Кроссплатформенный VPN-клиент для сотрудников: Windows и Android (позже iOS).
Построен на FlClash / Clash.Meta (GPL-3.0), см. [NOTICE.md](NOTICE.md).

## Что внутри

- Ядро mihomo (форк Clash.Meta) — VLESS+REALITY, XHTTP, Hysteria2.
- TUN-режим: Windows (служба `VPNskyHelperService`), Android (VpnService).
- Подписки: импорт по ссылке, автообновление.
- Сплит-туннель и режим «весь трафик» — переключаются профилем (правила маршрутизации).

## Сборка

Локально нужны Flutter 3.47.6, Go 1.27.1, Rust (для Windows-службы), Android NDK r28c.

```bash
flutter pub get
dart setup.dart windows -v      # Windows: dist/*.exe, dist/*.zip
dart setup.dart android -v      # Android: dist/*.apk
```

Или через GitHub Actions: workflow `build-vpnsky` (ручной запуск, artifacts в разделе Actions).

## Подпись Android

Для подписанного APK задайте секреты репозитория:
`ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
Без них собирается debug-APK (только для тестов).

## Наши изменения относительно upstream

См. [NOTICE.md](NOTICE.md), раздел «Что изменено».
