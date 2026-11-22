#!/usr/bin/env bash
# Отказы установщика без изменения системы: существующий Xray, занятый порт,
# прерванная установка, локальный target, подмена архива, вредоносный журнал.
# Только для одноразового контейнера без systemd (tests/run-docker.sh guards).
set -uo pipefail
T_NAME="guards"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
require_disposable

mapfile -t XSRC < <(xray_src_args)
# Быстрый детерминированный target без сети: домен указывает на 127.0.0.1
# и отклоняется проверкой адреса. Проверки REALITY - в reality_probe.sh и e2e.
grep -q 'guard.test' /etc/hosts || echo '127.0.0.1 guard.test' >>/etc/hosts
BASE=(--non-interactive --sni guard.test --server-address 127.0.0.1 "${XSRC[@]}")

state_paths=(/usr/local/bin/xray /usr/local/etc/xray /etc/systemd/system/xray.service /var/lib/mifa-vpn-basic)
assert_clean() { # префикс сообщения
  local p
  for p in "${state_paths[@]}"; do
    assert_false "$1: нет $p" test -e "$p"
  done
  assert_false "$1: нет пользователя xray" user_exists xray
}

run_install() { bash "$INSTALL_SH" "$@" 2>&1; }

t_section "Без systemd установка отклоняется до изменений"
out="$(run_install "${BASE[@]}")"; rc=$?
assert_rc "код 1" 1 "$rc"
assert_contains "причина: systemd" "$out" "systemd не запущен"
assert_contains "явное сообщение" "$out" "система не изменена"
assert_clean "без systemd"

t_section "Существующий бинарник Xray"
install -d /usr/local/bin
printf '#!/bin/sh\necho "Xray 1.0.0 fake"\n' >/usr/local/bin/xray
chmod 755 /usr/local/bin/xray
before="$(sha256sum /usr/local/bin/xray)"
out="$(run_install --preflight "${BASE[@]}")"; rc=$?
assert_rc "preflight: код 1" 1 "$rc"
assert_contains "preflight: сообщение" "$out" "существующая установка Xray"
assert_contains "preflight: доказательство" "$out" "найдено: /usr/local/bin/xray"
out="$(run_install "${BASE[@]}")"; rc=$?
assert_rc_nonzero "установка отклонена" "$rc"
assert_eq "бинарник не изменён" "$before" "$(sha256sum /usr/local/bin/xray)"
assert_false "конфиг не создан" test -e /usr/local/etc/xray
rm -f /usr/local/bin/xray

t_section "Существующий конфиг"
install -d -m 755 /usr/local/etc/xray
echo '{"inbounds": []}' >/usr/local/etc/xray/config.json
before="$(sha256sum /usr/local/etc/xray/config.json)"
out="$(run_install --preflight "${BASE[@]}")"
assert_contains "непустой /usr/local/etc/xray обнаружен" "$out" "/usr/local/etc/xray (не пуст)"
run_install "${BASE[@]}" >/dev/null
assert_eq "конфиг не изменён" "$before" "$(sha256sum /usr/local/etc/xray/config.json)"
rm -rf /usr/local/etc/xray

t_section "Пустой /usr/local/etc/xray не считается установкой"
install -d /usr/local/etc/xray
out="$(run_install --preflight "${BASE[@]}")"
assert_contains "нет ложного срабатывания" "$out" "существующей установки Xray не найдено"
rmdir /usr/local/etc/xray

t_section "Unit-файл и процесс xray"
install -d /etc/systemd/system
echo '[Service]' >/etc/systemd/system/xray.service
out="$(run_install --preflight "${BASE[@]}")"
assert_contains "unit xray.service обнаружен" "$out" "найдено: /etc/systemd/system/xray.service"
rm -f /etc/systemd/system/xray.service
# Процесс с именем xray (comm задаётся через prctl: в Ubuntu 26.04 sleep -
# multicall-бинарник uutils, его копия под другим именем не запускается).
python3 -c 'import ctypes, time; ctypes.CDLL(None).prctl(15, b"xray", 0, 0, 0); time.sleep(60)' &
fake_pid=$!
sleep 0.5
assert_eq "тестовый процесс называется xray" "xray" "$(cat "/proc/${fake_pid}/comm")"
out="$(run_install --preflight "${BASE[@]}")"
assert_contains "запущенный процесс xray обнаружен" "$out" "запущен процесс xray"
kill "$fake_pid" 2>/dev/null; wait "$fake_pid" 2>/dev/null

t_section "Повторная установка поверх Basic"
install -d -m 700 /var/lib/mifa-vpn-basic
echo 'mifa_basic_version=test' >/var/lib/mifa-vpn-basic/manifest
printf '#!/bin/sh\nexit 0\n' >/usr/local/bin/xray
chmod 755 /usr/local/bin/xray
out="$(run_install --preflight "${BASE[@]}")"
assert_contains "сообщение о готовой установке" "$out" "Basic уже установлен"
assert_contains "подсказка про данные клиента" "$out" "client.txt"
rm -rf /var/lib/mifa-vpn-basic /usr/local/bin/xray

t_section "Занятый порт"
lp="$(start_listener 8443)"
wait_port 8443 5
out="$(run_install --preflight "${BASE[@]}" --port 8443)"
assert_contains "порт 8443 занят" "$out" "Порт 8443/tcp занят"
out="$(run_install "${BASE[@]}" --port 8443)"; rc=$?
assert_rc_nonzero "установка на занятый порт отклонена" "$rc"
kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
out="$(run_install --preflight "${BASE[@]}" --port 8443)"
assert_contains "после освобождения порт свободен" "$out" "порт 8443/tcp свободен"
assert_clean "после проверок порта"

t_section "Журнал прерванной установки"
install -d -m 700 /var/lib/mifa-vpn-basic
printf '# test\n' >/var/lib/mifa-vpn-basic/journal.inprogress
out="$(run_install --preflight "${BASE[@]}")"
assert_contains "подсказка --rollback" "$out" "install.sh --rollback"
out="$(bash "$UNINSTALL_SH" --yes 2>&1)"; rc=$?
assert_rc_nonzero "uninstall.sh тоже отказывает" "$rc"
assert_contains "uninstall.sh: подсказка --rollback" "$out" "--rollback"

t_section "--rollback не выполняет недопустимые записи журнала"
passwd_before="$(sha256sum /etc/passwd)"
printf '#!/bin/sh\n' >/usr/local/bin/xray
jf=/var/lib/mifa-vpn-basic/journal.inprogress
printf 'remove\t/etc/passwd\t\nuserdel\troot\t\nremove\t/usr/local/etc/xray/../../../etc/shadow\t\nrestore\t/usr/local/etc/xray/config.json\t/tmp/evil\nremove\t/usr/local/bin/xray\t\nrmdir\t/var/lib/mifa-vpn-basic\t\n' \
  >"$jf"
out="$(bash "$INSTALL_SH" --rollback 2>&1)"; rc=$?
assert_rc "недопустимая запись: код 3" 3 "$rc"
assert_contains "предупреждение о недопустимой записи" "$out" "Недопустимая запись журнала"
assert_contains "журнал сохранён" "$out" "журнал ${jf} сохранён"
assert_eq "/etc/passwd не тронут" "$passwd_before" "$(sha256sum /etc/passwd)"
assert_true "/etc/shadow на месте" test -e /etc/shadow
assert_true "root на месте" user_exists root
assert_true "бинарник не тронут (откат прерван до изменений)" test -e /usr/local/bin/xray
assert_true "журнал сохранён" test -e "$jf"
assert_true "каталог состояния сохранён вместе с журналом" test -d /var/lib/mifa-vpn-basic
out="$(bash "$INSTALL_SH" --rollback 2>&1)"; rc=$?
assert_rc "повторный --rollback с тем же журналом: снова код 3" 3 "$rc"
assert_true "журнал сохранён после повтора" test -e "$jf"
# Даже разрешённые имена в старом журнале не доказывают принадлежность.
printf 'remove\t/usr/local/bin/xray\t\nrmdir\t/var/lib/mifa-vpn-basic\t\n' >"$jf"
out="$(bash "$INSTALL_SH" --rollback 2>&1)"; rc=$?
assert_rc "legacy undo без свидетельства: код 3" 3 "$rc"
assert_true "legacy журнал сохранён" test -e "$jf"
assert_true "legacy бинарник сохранён" test -e /usr/local/bin/xray
# These exact paths were created above, inside this disposable test container.
rm -f -- /usr/local/bin/xray "$jf"
rmdir -- /var/lib/mifa-vpn-basic
assert_clean "после --rollback"
out="$(bash "$INSTALL_SH" --rollback 2>&1)"; rc=$?
assert_rc "повторный --rollback: нечего откатывать" 0 "$rc"

t_section "uninstall.sh: установка без манифеста (Basic до 1.1)"
install -d /usr/local/bin /usr/local/etc/xray
printf '#!/bin/sh\nexit 0\n' >/usr/local/bin/xray
chmod 755 /usr/local/bin/xray
echo '{"legacy": true}' >/usr/local/etc/xray/config.json
legacy_sha="$(sha256sum /usr/local/etc/xray/config.json | awk '{print $1}')"
out="$(bash "$UNINSTALL_SH" --yes 2>&1)"; rc=$?
assert_rc_nonzero "без --force отказ" "$rc"
assert_contains "без --force: пояснение" "$out" "Чужой Xray не удаляется"
assert_true "без --force: бинарник на месте" test -e /usr/local/bin/xray
assert_eq "без --force: конфиг не изменён" "$legacy_sha" "$(sha256sum /usr/local/etc/xray/config.json | awk '{print $1}')"
out="$(bash "$UNINSTALL_SH" --yes --force 2>&1)"; rc=$?
assert_rc "--force: код 0" 0 "$rc"
bk="$(sed -n 's/^Резервная копия конфига и данных клиента: //p' <<<"$out")"
assert_eq "--force: конфиг сохранён в резервной копии" "$legacy_sha" "$(sha256sum "${bk}/usr/local/etc/xray/config.json" 2>/dev/null | awk '{print $1}')"
assert_false "--force: бинарник удалён" test -e /usr/local/bin/xray
assert_false "--force: конфиг удалён" test -e /usr/local/etc/xray
rm -rf /var/backups/mifa-vpn-basic
assert_clean "после uninstall --force"

t_section "Локальный и частный target отклоняются"
for t in 127.0.0.1:443 10.0.0.1:443 192.168.0.1:443 169.254.169.254:443 "[::1]:443"; do
  out="$(run_install --preflight --sni example.com --target "$t" --server-address 127.0.0.1 "${XSRC[@]}")"
  assert_contains "target $t отклонён" "$out" "локальный или частный адрес"
done
echo '169.254.169.254 metadata.test' >>/etc/hosts
out="$(run_install --preflight --sni metadata.test --server-address 127.0.0.1 "${XSRC[@]}")"
assert_contains "домен на metadata-адрес отклонён" "$out" "локальный или частный адрес (169.254.169.254)"

t_section "Целостность архива Xray"
W="$(mktemp -d)"
tmp_before="$(find /tmp -maxdepth 1 -name 'mifa-basic.*' | wc -l)"
head -c 4096 /dev/urandom >"${W}/fake.zip"
out="$(run_install --dry-run "${BASE[@]}" --xray-zip "${W}/fake.zip")"; rc=$?
assert_rc_nonzero "подменённый архив: код ошибки" "$rc"
assert_contains "подменённый архив отклонён по SHA256" "$out" "SHA256 архива Xray не совпадает"
assert_not_contains "подменённый архив не распакован" "$out" "запускается"
python3 - "${W}/old.zip" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
info = zipfile.ZipInfo("xray")
info.external_attr = 0o755 << 16
z.writestr(info, "#!/bin/sh\necho 'Xray 1.0.0 (fake)'\n")
z.close()
PY
old_sha="$(sha256sum "${W}/old.zip" | awk '{print $1}')"
out="$(run_install --dry-run "${BASE[@]}" --xray-zip "${W}/old.zip" --xray-sha256 "$old_sha")"; rc=$?
assert_rc_nonzero "архив с другой версией: код ошибки" "$rc"
assert_contains "проверка версии бинарника" "$out" "Версия Xray не совпадает"
if [[ -n "${MIFA_TEST_XRAY_ZIP:-}" ]]; then
  out="$(run_install --dry-run "${BASE[@]}" --xray-sha256 "$(printf '0%.0s' $(seq 1 64))")"; rc=$?
  assert_contains "настоящий архив с чужим SHA256 отклонён" "$out" "SHA256 архива Xray не совпадает"
  out="$(run_install --dry-run "${BASE[@]}")"; rc=$?
  assert_contains "настоящий архив: SHA256 подтверждён" "$out" "SHA256 архива Xray подтверждён"
  assert_contains "настоящий архив: xray run -test" "$out" "конфиг"
  assert_contains "настоящий архив: dry-run дошёл до конца" "$out" "Dry-run завершён"
  assert_contains "dry-run скрывает privateKey" "$(grep '"privateKey"' <<<"$out")" '"privateKey": "<скрыто>"'
else
  echo "  SKIP  проверки с настоящим архивом: MIFA_TEST_XRAY_ZIP не задан"
fi
assert_eq "временные каталоги dry-run удалены" "$tmp_before" "$(find /tmp -maxdepth 1 -name 'mifa-basic.*' | wc -l)"
rm -rf "$W"
assert_clean "после проверок архива"

t_summary
