# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog principles
and Semantic Versioning.

---

## [1.1.0] - 2026-11-22

Выпуск на основе проверенного RC1: версия установщика и документация
синхронизированы с 1.1.0 без изменения алгоритмов установки и rollback.

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

- P1-4: restore с порядком `restoring/restored`, синхронизацией намерения
  до замены, уникальным приватным staging и независимой проверкой результата.
  Чужой staging не перезаписывается, каталог назначения отклоняется;
  неоднозначный повтор и незавершённый v1 restore завершаются с кодом 3.
- P1-2 / journal v3: уникальные ID, синхронизируемые prepare/ready
  и undoing/undone, поколения xattrs для файлов/каталогов, GECOS для пользователя
  и заблокированного поля gshadow для его новой приватной группы.
  После незавершённого undo — только проверка результата, без повторной мутации.
  Legacy remove/rmdir/chmeta/userdel отклоняются с кодом 3; restore v2 сохранён.
- P1-3: проверки путей журнала и backup, открытие родительских каталогов
  без следования симлинкам и изменение метаданных через дескрипторы.
- P1-5: проверка принадлежности systemd unit и stop/disable-барьер до файловых
  действий, даже при отсутствии записи `stop`; новая установка журналирует
  `stop` до `enable`. Чужая или неоднозначная служба не останавливается.
- Адресные исправления ShellCheck для вызова rollback и тестовых моков.

### Validation
- Предусмотренные регрессии P1-2/P1-3/P1-4/P1-5 прошли на Ubuntu 24.04:
  целевой P1-4 baseline — 25 PASS; smoke journal v3 — 15 PASS по P1-2;
  завершающий [basic-freeze](https://github.com/kolpakovden/mifa-vpn-basic/actions/runs/45001212778) — 20 PASS / 0 FAIL.
  Известные отрицательные контроли ранних запусков затем исправлены.
- [Финальный E2E Ubuntu 24.04](https://github.com/kolpakovden/mifa-vpn-basic/actions/runs/45003759931)
  на RC1 — 23 PASS / 0 FAIL: установка и systemd, SIGKILL перед commit,
  работающий VPN и настоящий запрос VLESS/REALITY после прерывания,
  успешный rollback, повторная установка и повторный запрос.
- [Обычный CI на main RC1](https://github.com/kolpakovden/mifa-vpn-basic/actions/runs/45004262794)
  прошёл для Ubuntu 22.04, 24.04 и 26.04.

### Limitations
- Только чистый сервер, без миграции существующего Xray. Нужны systemd,
  Python 3 и user xattrs. Пустой служебный каталог и поколения восстановленных
  каталогов после rollback сохраняются; неоднозначность требует ручного решения.
- Полный повтор 25 сценариев P1-4 на финальном коде и полная матрица rollback
  для всех Ubuntu не выполнялись. E2E использует локальную TLS/HTTP-цель;
  отдельная проверка из внешней сети не проводилась. Полная защита от TOCTOU
  с конкурентным root, полная атомарность и восстановление после потери питания
  не подтверждены.

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
