# Восстановление и устранение проблем

Инструкции относятся к установке, созданной `install.sh` этой версии Basic.
Команды выполняются на сервере от root или через `sudo`. Процедуры 1, 2, 4 и 5
проверяются автоматически в `tests/e2e_systemd.sh`.

Пути Basic:

| Путь | Назначение |
|------|------------|
| `/usr/local/bin/xray` | бинарник Xray |
| `/usr/local/etc/xray/config.json` | конфиг сервера, содержит закрытый ключ |
| `/etc/systemd/system/xray.service` | unit systemd |
| `/var/lib/mifa-vpn-basic/client.txt` | данные клиента и ссылка `vless://` |
| `/var/lib/mifa-vpn-basic/manifest` | список файлов установки |
| `/var/lib/mifa-vpn-basic/journal.inprogress` | журнал незавершённой установки |
| `/var/backups/mifa-vpn-basic/` | резервные копии |

## 1. Установка завершилась ошибкой

Установщик сам откатывает все изменения и пишет:

```
[OK] Откат завершён: изменения установщика отменены
```

Исправьте причину из сообщения выше этой строки и запустите установку снова.
Если вместо этого выведено `Откат завершён с предупреждениями`, проверьте
перечисленные пути вручную (раздел 6).

Не откатывается только пакет `unzip`, если установщик ставил его через `apt-get`.

## 2. Установка прервана: обрыв SSH, перезагрузка, kill

Признак: preflight сообщает

```
[FAIL] найден журнал незавершённой установки /var/lib/mifa-vpn-basic/journal.inprogress
```

Откат по журналу:

```bash
sudo bash install.sh --rollback
```

Затем установка заново. `--rollback` выполняет только допустимые действия над
путями Basic: остановить и отключить `xray.service`, удалить созданные файлы,
восстановить файлы из `/var/backups/mifa-vpn-basic`, удалить созданного
пользователя `xray`. Посторонние записи пропускаются с предупреждением.

Чтобы не попадать в эту ситуацию, запускайте установку в `tmux` или `screen`.

## 3. Сервис не запускается или падает

Состояние и журнал:

```bash
sudo systemctl status xray --no-pager
```

```bash
sudo journalctl -u xray -n 100 --no-pager
```

Проверка конфига от имени пользователя сервиса:

```bash
sudo -u xray /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
```

Кто занимает порт (замените 443 на свой):

```bash
sudo ss -tlnp 'sport = :443'
```

Код выхода 23 означает ошибку конфига: systemd не перезапускает сервис, пока
конфиг не исправлен.

## 4. Вернуть прежние ключи и ссылку

Сценарий: Basic удалён `uninstall.sh` или переустановлен, а клиенты должны
продолжить работать с прежней ссылкой. `uninstall.sh` перед удалением сохраняет
конфиг и данные клиента и печатает каталог резервной копии:

```
Резервная копия конфига и данных клиента: /var/backups/mifa-vpn-basic/uninstall-20261121T120000Z
```

1. Установите Basic заново с **тем же портом и SNI**, что и в резервной копии
   (их можно посмотреть в `client.txt` копии):

   ```bash
   sudo cat /var/backups/mifa-vpn-basic/uninstall-20261121T120000Z/var/lib/mifa-vpn-basic/client.txt
   ```

   ```bash
   sudo bash install.sh --sni DOMAIN --port PORT
   ```

2. Остановите сервис:

   ```bash
   sudo systemctl stop xray
   ```

3. Верните конфиг и данные клиента из копии (подставьте свой каталог):

   ```bash
   BK=/var/backups/mifa-vpn-basic/uninstall-20261121T120000Z
   ```

   ```bash
   sudo install -m 0640 -o root -g xray "$BK/usr/local/etc/xray/config.json" /usr/local/etc/xray/config.json
   ```

   ```bash
   sudo install -m 0600 -o root -g root "$BK/var/lib/mifa-vpn-basic/client.txt" /var/lib/mifa-vpn-basic/client.txt
   ```

4. Проверьте конфиг и запустите сервис:

   ```bash
   sudo -u xray /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
   ```

   ```bash
   sudo systemctl start xray
   ```

Прежняя ссылка снова работает. Новые ключи, созданные на шаге 1, больше не нужны.

## 5. Переустановка с новыми ключами

```bash
sudo bash uninstall.sh
```

```bash
sudo bash install.sh --sni DOMAIN --port PORT
```

Старые ссылки клиентов перестают работать. Резервная копия прежнего конфига
остаётся в `/var/backups/mifa-vpn-basic/`.

## 6. Ручная очистка

Нужна, только если `uninstall.sh` или `--rollback` завершились с предупреждениями.
Сначала сохраните конфиг, если он нужен:

```bash
sudo cp -a /usr/local/etc/xray /root/xray-config-backup
```

```bash
sudo systemctl disable --now xray
```

```bash
sudo rm -f /etc/systemd/system/xray.service /usr/local/bin/xray
```

```bash
sudo rm -rf /usr/local/etc/xray /var/lib/mifa-vpn-basic
```

```bash
sudo systemctl daemon-reload
```

```bash
sudo userdel xray
```

`userdel` нужен, только если пользователя `xray` создал Basic (`user_created=1`
в манифесте).

## 7. Клиент не подключается

Проверьте по порядку:

1. Сервис активен и слушает порт (раздел 3).
2. Порт открыт в панели провайдера и в `ufw` (`sudo ufw status`).
3. В ссылке правильный адрес сервера. Если вместо адреса стоит `YOUR_SERVER_IP`,
   внешний IP не определился: замените его вручную.
4. На устройстве клиента верное время.
5. Подключение проверяется с другого устройства и из другой сети.
6. Цель REALITY всё ещё проходит проверку:

   ```bash
   bash install.sh --preflight --sni DOMAIN --port PORT
   ```

   На установленном сервере preflight сообщит, что Basic уже установлен; строки
   про REALITY при этом проверяются как обычно.

## 8. Установки Basic до версии 1.1

Старые версии не создавали манифест и могли ставить Xray через сторонний APT
или официальный скрипт XTLS. Удаление с резервной копией:

```bash
sudo bash uninstall.sh --force
```

Если Xray установлен APT-пакетом, `uninstall.sh` откажется и предложит
`sudo apt-get purge xray`. Логи старых версий в `/var/log/xray` не удаляются.
