## Mifa-VPN-basic

![Version](https://img.shields.io/badge/version-v1.0.1-blue)
[![License](https://img.shields.io/badge/license-Free_Noncommercial-blue)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Ubuntu-orange)

Minimal Xray (VLESS + Reality) installer for a **clean Ubuntu VPS**. The installer's security and compatibility hardening is in progress; it is not yet a general-purpose migration tool.

> Default RU-friendly port: **8443**  
> Supports modern **Xray v26+ (Password/pbk format)**  
> Clean, minimal, no telemetry.

### Looking for Advanced Features?

If you need:

- Telegram-based user management  
- Monitoring (Grafana + Prometheus + Loki)  
- Modular architecture  
- Production-grade observability  

The advanced architecture is maintained in **[MIFA VPN Core](https://github.com/kolpakovden/mifa-vpn-core)** (currently a private development repository). The former [MIFA VPN Platform](https://github.com/kolpakovden/mifa-vpn-platform) is preserved only for historical reference.

---

## Features

```
Minimal and clean Xray installer
VLESS + Reality configuration
RU-friendly default port: 8443
Configurable port (--port, --443, --8443)
Configurable SNI/target
Non-interactive mode (--non-interactive)
Automatic UUID generation
Automatic Reality key generation
Supports Xray v26+ (Password/pbk format)
systemd service integration
Ready-to-import VLESS URI output
```

## Reality Key Compatibility
This installer supports both:
Legacy Xray output
```
Private key
Public key
```
Xray v26+ output
```
PrivateKey
Password
```
The script automatically detects and parses the correct format.

## Installation

**Important: fresh hosts only.** The installer now rejects a machine with an existing Xray executable, configuration or running Xray service before attempting to write a config. Never run it to update a production VPN. Do not assume a fixed SNI/target is valid for every network; verify it before using a profile.

Recommended: start with a fresh Ubuntu VPS. Allow the selected TCP port in your VPS provider firewall and any local firewall. Save the generated VLESS link securely. Test from a separate device/network before relying on it.

```bash
git clone https://github.com/kolpakovden/mifa-vpn-basic.git
cd mifa-vpn-basic
sudo bash install.sh --port 8443 --sni vpn.example.com --target vpn.example.com:443
```

Replace `vpn.example.com` with a **verified compatible REALITY handshake target**; this is a parameter example, not a ready-to-use SNI. An automated compatibility test will be added before the next public release.

The script currently contains legacy installation paths and does not yet implement complete rollback. Track production-readiness work in [Issue #1](https://github.com/kolpakovden/mifa-vpn-basic/issues/1).

### Legacy quick start

```
git clone https://github.com/kolpakovden/MIFA-VPN-basic.git
cd MIFA-VPN-basic
sudo bash install.sh
```

## Security Note

Reality is a transport obfuscation layer, not a full anonymity system.
This project:
```
Protects traffic from simple DPI
Obfuscates TLS handshake
Helps bypass censorship in restrictive networks
```
This project does NOT:
```
Provide anonymity like Tor
Protect against endpoint compromise
Prevent server-side logging
Protect against traffic correlation attacks
```
You are responsible for proper operational security (OPSEC).

## Edition Comparison

| Feature | Basic | Core (private development) |
|----------|--------|-----------|
| Xray (VLESS + Reality) |   ✅ |   ✅ |
| Telegram Bot |   ❌ |   ✅ |
| Monitoring Stack |   ❌ |   ✅ |
| Architecture | Monolithic | Modular |
| Target | Simple Setup | Production Infra |


## License

Цель проекта — **бесплатная доступность для всех без коммерческой эксплуатации**.

С 24 октября 2026 года новые разрешения на собственные материалы проекта предоставляются по [MIFA Free Noncommercial License 1.0](LICENSE).

- Разрешены бесплатное некоммерческое использование, изучение, изменение и бесплатное распространение.
- Необходимо сохранять уведомления об авторстве, текст лицензии и ссылку на этот репозиторий; изменения нужно обозначать.
- Запрещены продажа проекта и производных, платный VPN и другие монетизируемые сервисы на их основе.
- Запрещены платные установка, настройка, размещение, сопровождение, поддержка, консультации и обучение по проекту.
- Оплата собственного сервера или подключения независимому провайдеру для разрешённого некоммерческого использования допускается.

**Ранее выданные права MIT сохраняются.** Код и другие материалы, ранее опубликованные под MIT, можно продолжать использовать по MIT, включая коммерческое использование. Замена лицензии не делает прежний код исключительно некоммерческим. Это особенно существенно для архивных версий, где новых разработок может не быть.

Сторонние компоненты и материалы сохраняют собственные лицензии и авторство. Условия этого репозитория не заменяют лицензии Xray, Grafana, Loki и других зависимостей.

Это собственная некоммерческая лицензия с доступными исходниками, а не MIT и не стандартная open source лицензия. Материалы предоставляются «как есть», без гарантий.

## Disclaimer

```
This project is intended for infrastructure automation and educational purposes.
Ensure compliance with local laws and regulations in your jurisdiction.
```
