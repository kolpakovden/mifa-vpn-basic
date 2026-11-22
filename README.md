## MIFA VPN Basic

![Version](https://img.shields.io/badge/version-v1.1.0-blue)
[![License](https://img.shields.io/badge/license-Free_Noncommercial-blue)](LICENSE)

Простой установщик **Xray (VLESS + REALITY)** для чистого VPS с Ubuntu **22.04 / 24.04 / 26.04** (x86_64 и ARM64).

Автоматически проверяет сервер, устанавливает Xray, создаёт ключи и выдаёт готовую ссылку для подключения.

## Установка

**1.** Подключитесь к новому VPS по SSH. На сервере не должно быть установленного Xray или VPN-панелей.

**2.** Скачайте стабильную версию:

```bash
git clone --depth 1 --branch v1.1.0 https://github.com/kolpakovden/mifa-vpn-basic.git
cd mifa-vpn-basic
```

**3.** Проверьте сервер и установите VPN:

```bash
sudo bash install.sh --preflight --sni YOUR_DOMAIN --port 443
sudo bash install.sh --sni YOUR_DOMAIN --port 443
```

Замените `YOUR_DOMAIN` на реальный публичный домен, поддерживающий TLS 1.3, X25519 и HTTP/2. Установщик проверит его пригодность. Порт `443/tcp` должен быть свободен и открыт в firewall VPS и панели провайдера. При необходимости используйте `8443` вместо `443`.

## Подключение

После установки скрипт покажет ссылку `vless://`. Импортируйте её в совместимый клиент **VLESS + REALITY**, например:

- [Hiddify](https://github.com/hiddify/hiddify-app) - Windows, Android, iOS, macOS, Linux;
- [v2RayTun](https://github.com/LXST-CODE/v2RayTun) - клиенты для различных платформ;
- [NekoBox for Android](https://github.com/MatsuriDayo/NekoBoxForAndroid) - Android (репозиторий архивирован).

Проверьте подключение с другого устройства или через другую сеть.

## Управление

| Действие | Команда |
|---|---|
| Повторно получить ссылку подключения | `sudo cat /var/lib/mifa-vpn-basic/client.txt` |
| Статус Xray | `sudo systemctl status xray` |
| Перезапустить Xray | `sudo systemctl restart xray` |
| Посмотреть логи | `sudo journalctl -u xray -n 50` |
| Удалить VPN (с резервной копией) | `sudo bash uninstall.sh` |
| Откатить прерванную установку | `sudo bash install.sh --rollback` |


## Важно

- Basic предназначен **только для чистого VPS**: не обновляет существующий Xray и не переносит его конфигурацию.
- Нужны `root` или `sudo`, работающий `systemd` и доступ к GitHub для загрузки Xray.
- Установщик **не открывает порты** в firewall автоматически. Для установки желательно использовать `tmux` или `screen` на случай разрыва SSH.
- Обычные проверки пройдены на Ubuntu 22.04/24.04/26.04; E2E с настоящим Xray-клиентом - на Ubuntu 24.04. Подключение с внешнего устройства в этих проверках не тестировалось.

**Документация:** [Восстановление](docs/RECOVERY.md) · [История изменений](CHANGELOG.md) · [Релизы](https://github.com/kolpakovden/mifa-vpn-basic/releases)

**Лицензия:** [MIFA Free Noncommercial License 1.0](LICENSE) - бесплатное некоммерческое использование. Ранее предоставленные права MIT сохраняются для соответствующих материалов. Проект предоставляется без гарантий.
