# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog principles
and Semantic Versioning.

---

## [Unreleased]

Hardening по Issue #1. Не выпускается до зелёного CI и проверки внешним клиентом.

### Added
- Режимы `--preflight`, `--plan` и `--dry-run` без изменения системы.
- Проверка REALITY-цели: DNS, запрет локальных и частных адресов, петля на сам сервер,
  TLS 1.3, X25519, HTTP/2, действительный сертификат для SNI, предупреждение о редиректе.
- Журнал изменений, автоматический откат и `--rollback` для прерванной установки.
- Данные клиента в `/var/lib/mifa-vpn-basic/client.txt` (0600), манифест установки.
- `--server-address`, `--no-print-secrets`, `--yes`, `--xray-zip`, `--xray-version` с `--xray-sha256`.
- Тесты: unit, REALITY-проверка, отказы без изменений, режимы без изменений,
  e2e в контейнере с systemd; CI для Ubuntu 22.04, 24.04, 26.04 и сверка SHA256 Xray.
- Русский README, `docs/RECOVERY.md`, `docs/AUDIT.md`.

### Changed
- `--sni` обязателен: домен по умолчанию больше не выбирается молча.
- Xray ставится только из официального релиза закреплённой версии v26.11.9 с проверкой SHA256.
- Собственный unit systemd: пользователь `xray`, `NoNewPrivileges`, `ProtectSystem=strict` и др.
- Журнал посещений отключён, ошибки Xray пишутся в journald вместо `/var/log/xray`.
- Повторная установка поверх существующего Xray отклоняется без изменений.
- `uninstall.sh` делает резервную копию, удаляет только файлы Basic и не трогает чужой Xray без `--force`.

### Removed
- Установка через сторонний APT-репозиторий `deb.xray.guru` и через `curl | bash`.

### Fixed
- Разбор вывода `xray x25519` в формате Xray v26.11+ (`Password (PublicKey)`).
- Проверка порта больше не считает порт свободным при отсутствии `ss`; ведущие нули отклоняются.
- В ссылку VLESS добавлен `encryption=none`, IPv6-адрес сервера заключается в скобки.

### Experimental — rollback baseline
- Незавершённый прототип: проверка записей журнала, обработка записанных
  `stop`/`disable` перед файловыми действиями, код 3 при обнаруженном неполном
  откате и маркер `restored`. Это не подтверждённые исправления безопасности.
- Подготовлены регрессионные тесты и ограниченный bootstrap baseline.
  Текущий rollback ещё не прошёл Linux-регрессии на Ubuntu 22.04/24.04/26.04;
  ожидаются падения сценариев повторного отката, симлинков, staging и остановки
  службы. Окно сбоя перед записью `restored` также остаётся риском.
- Успешные self-tests инфраструктуры не означают готовности установщика к релизу.
- После baseline `95b85de`: подготовлено P1-4 — journal v2 с проверкой
  `restoring/restored`, уникальный приватный staging, проверка результата restore
  и отказ от неоднозначного незавершённого v1 restore. Нужен `python3` для
  проверки восстановления обычных файлов. Linux-проверка исправления ещё не выполнена;
  P1-2/P1-3/P1-5 остаются открытыми, полная защита от TOCTOU не заявляется.

---

## [1.0.0] - 2026-02-27

### Added
- Initial stable release
- Xray (VLESS + Reality) installer
- RU-friendly default port 8443
- Configurable port flags
- Configurable SNI / target flags
- Non-interactive mode
- Automatic UUID generation
- Automatic Reality key generation
- Support for Xray v26+ (Password/pbk format)
- systemd integration
- Ready-to-import VLESS URI output
