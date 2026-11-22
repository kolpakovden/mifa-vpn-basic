#!/usr/bin/env bash
# Unit-тесты функций install.sh. Не меняют систему, root не нужен.
# Необязательно: MIFA_TEST_XRAY_BIN - настоящий бинарник xray для сверки.
set -uo pipefail
T_NAME="unit"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

MIFA_BASIC_LIB=1
# shellcheck source=install.sh
. "$INSTALL_SH"
set +e +E
trap - ERR
# Only temporary unit fixtures; production parent guards run in Linux regressions.
txn_restore_parents_safe() { return 0; }
FIX="${TESTS_DIR}/fixtures"

if [[ -z "${MIFA_TEST_XRAY_BIN:-}" && -n "${MIFA_TEST_XRAY_ZIP:-}" ]] && command -v python3 >/dev/null 2>&1; then
  XRAY_TMP="$(mktemp -d)"
  python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract("xray", sys.argv[2])' "$MIFA_TEST_XRAY_ZIP" "$XRAY_TMP"
  chmod 755 "${XRAY_TMP}/xray"
  MIFA_TEST_XRAY_BIN="${XRAY_TMP}/xray"
fi

t_section "validate_port"
for p in 1 22 443 8443 65535; do assert_true "порт $p допустим" validate_port "$p"; done
for p in 0 65536 99999 08443 -1 abc "" 1e3 " 443"; do assert_false "порт '$p' отклонён" validate_port "$p"; done

t_section "validate_domain"
for d in example.com www.microsoft.com a.b xn--80ak6aa92e.com reality-target.test a-b.c-d.example; do
  assert_true "домен $d допустим" validate_domain "$d"
done
long_label="$(printf 'a%.0s' $(seq 1 64)).com"
long_name="$(printf 'abcdefghi.%.0s' $(seq 1 26))com"
# shellcheck disable=SC2016
for d in "" com .a.b a..b -a.b a-.b a.b. 1.2.3.4 a_b.com "a b.com" "a.b;rm" 'a.b$(x)' "$long_label" "$long_name" EXAMPLE.COM; do
  assert_false "домен '${d:0:40}' отклонён" validate_domain "$d"
done

t_section "validate_ipv4 / validate_ipv6"
for ip in 1.2.3.4 0.0.0.0 255.255.255.255 198.51.100.11; do assert_true "IPv4 $ip допустим" validate_ipv4 "$ip"; done
for ip in 256.1.1.1 01.2.3.4 1.2.3 1.2.3.4.5 a.b.c.d ""; do assert_false "IPv4 '$ip' отклонён" validate_ipv4 "$ip"; done
for ip in ::1 2001:db8::1 ::ffff:1.2.3.4; do assert_true "IPv6 $ip допустим" validate_ipv6 "$ip"; done
for ip in 1.2.3.4 "fe80::1%eth0" "zz::1" ""; do assert_false "IPv6 '$ip' отклонён" validate_ipv6 "$ip"; done

t_section "parse_target"
parse_target "Example.COM:443"
assert_eq "домен и порт, нижний регистр" "example.com|443" "${TARGET_HOST}|${TARGET_PORT}"
parse_target "1.2.3.4:8443"
assert_eq "IPv4 и порт" "1.2.3.4|8443" "${TARGET_HOST}|${TARGET_PORT}"
parse_target "[2001:db8::1]:443"
assert_eq "IPv6 в скобках" "2001:db8::1|443" "${TARGET_HOST}|${TARGET_PORT}"
for t in example.com example.com:0 example.com:65536 ":443" "exa mple.com:443" "example.com:443:1" "[zz]:443" "2001:db8::1:443" "a..b:443" "example.com:08443"; do
  assert_false "target '$t' отклонён" parse_target "$t"
done

t_section "is_restricted_ip"
for ip in 127.0.0.1 127.8.8.8 10.1.2.3 172.16.0.1 172.31.255.255 192.168.1.1 169.254.169.254 100.64.0.1 \
          100.127.255.254 0.0.0.0 224.0.0.1 255.255.255.255 192.0.0.8 198.18.0.1 198.19.1.1 \
          ::1 :: fe80::1 fd00::1 fc00::1 ff02::1 fec0::1 ::ffff:127.0.0.1 ::ffff:10.0.0.1 0:0:0:0:0:0:0:1 not-an-ip; do
  assert_true "адрес $ip запрещён как target" is_restricted_ip "$ip"
done
for ip in 1.1.1.1 8.8.8.8 172.15.0.1 172.32.0.1 100.63.0.1 100.128.0.1 198.51.100.11 203.0.113.5 \
          2606:4700::1111 2001:db8::1 ::ffff:8.8.8.8 fc::1 fb00::1; do
  assert_false "адрес $ip разрешён как target" is_restricted_ip "$ip"
done

t_section "parse_x25519: форматы вывода xray"
want_priv="UAoklA14FnQz8Ham05nopTU1GMvLVNJH5ElrjGectXY"
want_pub="mXeg_DZ2Kea9H3d1g793pI60g-70eGPq-uns7zJLVAY"
for f in x25519-legacy.txt x25519-v25.txt x25519-v26.11.txt; do
  X25519_PRIVATE=""; X25519_PUBLIC=""
  assert_true "$f разобран" parse_x25519 "$(cat "${FIX}/${f}")"
  assert_eq "$f: закрытый ключ" "$want_priv" "$X25519_PRIVATE"
  assert_eq "$f: открытый ключ" "$want_pub" "$X25519_PUBLIC"
done
assert_true "CRLF после tr -d '\\r' разобран" parse_x25519 "$(tr -d '\r' <"${FIX}/x25519-v26.11-crlf.txt")"
assert_false "Hash32 не принимается за открытый ключ" parse_x25519 "PrivateKey: ${want_priv}
Hash32: VCXkjMW_mhs9v0Z-3uakpSRw8CcRDEAK-S1R6sK514U"
assert_false "мусор отклонён" parse_x25519 "error: something went wrong"
assert_false "короткий ключ отклонён" parse_x25519 "PrivateKey: abc
Password: def"

t_section "x25519_public_from_private (openssl)"
WORKDIR="$(mktemp -d)"
# shellcheck disable=SC2001
hex_to_b64url() { printf '%b' "$(sed 's/../\\x&/g' <<<"$1")" | b64url_encode; }
alice_priv="$(hex_to_b64url 77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a)"
alice_pub="$(hex_to_b64url 8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a)"
assert_eq "RFC 7748, вектор Alice" "$alice_pub" "$(x25519_public_from_private "$alice_priv")"
assert_eq "фикстура от Xray v26.11.9" "$want_pub" "$(x25519_public_from_private "$want_priv")"
assert_eq "временный DER-файл удалён" "" "$(ls -A "$WORKDIR")"

t_section "build_vless_uri"
CLIENT_UUID="4ddc1eed-4be4-47f8-968f-1baedd909675"
REALITY_PUBLIC_KEY="$want_pub"
SHORT_ID="0123456789abcdef"
PORT=8443
SNI="www.example.com"
SERVER_ADDRESS="203.0.113.10"
assert_eq "URI для IPv4" \
  "vless://4ddc1eed-4be4-47f8-968f-1baedd909675@203.0.113.10:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com&fp=chrome&pbk=${want_pub}&sid=0123456789abcdef&type=tcp&headerType=none#MIFA-VPN-basic" \
  "$(build_vless_uri)"
SERVER_ADDRESS="2001:db8::10"
assert_contains "IPv6-адрес сервера в скобках" "$(build_vless_uri)" "@[2001:db8::10]:8443?"

t_section "render_config / redact_config"
REALITY_PRIVATE_KEY="$want_priv"
TARGET="www.example.com:443"
cfg="$(render_config)"
if command -v python3 >/dev/null 2>&1; then
  assert_true "конфиг - корректный JSON" python3 -c 'import json,sys; json.loads(sys.argv[1])' "$cfg"
  get() { python3 -c 'import json,sys; c=json.loads(sys.argv[1]); print(eval(sys.argv[2], {"c": c}))' "$cfg" "$1"; }
  assert_eq "порт" "8443" "$(get 'c["inbounds"][0]["port"]')"
  assert_eq "flow" "xtls-rprx-vision" "$(get 'c["inbounds"][0]["settings"]["clients"][0]["flow"]')"
  assert_eq "access-лог отключён" "none" "$(get 'c["log"]["access"]')"
  assert_eq "serverNames" "['www.example.com']" "$(get 'c["inbounds"][0]["streamSettings"]["realitySettings"]["serverNames"]')"
  assert_eq "блокировка metadata и localhost" "True True" \
    "$(get '" ".join(str(x in c["routing"]["rules"][0]["ip"]) for x in ["169.254.0.0/16", "127.0.0.0/8"])')"
fi
red="$(render_config | redact_config)"
assert_not_contains "redact скрывает privateKey" "$red" "$want_priv"
assert_not_contains "redact скрывает UUID" "$red" "$CLIENT_UUID"
assert_not_contains "redact скрывает shortId" "$red" "$SHORT_ID"
if [[ -n "${MIFA_TEST_XRAY_BIN:-}" ]]; then
  render_config >"${WORKDIR}/config.json"
  assert_true "настоящий xray run -test принимает конфиг" test_config "$MIFA_TEST_XRAY_BIN" "${WORKDIR}/config.json"
  out="$("$MIFA_TEST_XRAY_BIN" x25519 2>&1 | tr -d '\r')"
  assert_true "вывод настоящего xray x25519 разобран" parse_x25519 "$out"
  assert_eq "openssl и xray дают одинаковый открытый ключ" "$X25519_PUBLIC" "$(x25519_public_from_private "$X25519_PRIVATE")"
  gen="$( (generate_credentials "$MIFA_TEST_XRAY_BIN" >/dev/null && printf '%s %s %s' "$CLIENT_UUID" "$REALITY_PUBLIC_KEY" "$SHORT_ID") 2>&1 )"
  read -r g_uuid g_pub g_sid <<<"$gen"
  assert_true "generate_credentials: UUID корректен" validate_uuid "${g_uuid:-}"
  assert_true "generate_credentials: открытый ключ корректен" validate_x25519_key "${g_pub:-}"
  assert_true "generate_credentials: shortId из 16 hex" test "${#g_sid}" -eq 16
else
  echo "  SKIP  сверка с настоящим xray: MIFA_TEST_XRAY_BIN не задан"
fi
rm -rf "$WORKDIR"

t_section "render_unit"
unit="$(render_unit)"
for s in "User=xray" "NoNewPrivileges=true" "ProtectSystem=strict" "CapabilityBoundingSet=CAP_NET_BIND_SERVICE" \
         "ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json" "RestartPreventExitStatus=23"; do
  assert_contains "unit содержит $s" "$unit" "$s"
done

t_section "journal_entry_allowed: защита --rollback"
assert_true "remove бинарника" journal_entry_allowed remove /usr/local/bin/xray ""
assert_true "remove временного файла" journal_entry_allowed remove /usr/local/bin/xray.mifa-new.123 ""
assert_true "rmdir каталога конфига" journal_entry_allowed rmdir /usr/local/etc/xray ""
assert_true "stop xray.service" journal_entry_allowed stop xray.service ""
assert_true "userdel xray" journal_entry_allowed userdel xray ""
assert_true "restore из резервной копии" journal_entry_allowed restore /usr/local/etc/xray/config.json /var/backups/mifa-vpn-basic/install-1/usr/local/etc/xray/config.json
assert_false "remove /etc/passwd запрещён" journal_entry_allowed remove /etc/passwd ""
assert_false "обход через .. запрещён" journal_entry_allowed remove /usr/local/etc/xray/../../../etc/shadow ""
assert_false "userdel root запрещён" journal_entry_allowed userdel root ""
assert_false "stop sshd запрещён" journal_entry_allowed stop ssh.service ""
assert_false "restore из чужого пути запрещён" journal_entry_allowed restore /usr/local/etc/xray/config.json /tmp/evil
assert_false "неизвестное действие запрещено" journal_entry_allowed exec /usr/local/bin/xray ""
assert_true "restored для manifest допустим" journal_entry_allowed restored /var/lib/mifa-vpn-basic/manifest /var/backups/mifa-vpn-basic/install-1/var/lib/mifa-vpn-basic/manifest
assert_false "restored из чужого пути запрещён" journal_entry_allowed restored /var/lib/mifa-vpn-basic/manifest /tmp/evil

t_section "txn_file_matches: файлы и символические ссылки"
TDIR="$(mktemp -d)"
printf 'a\n' >"${TDIR}/ref"
cp -a "${TDIR}/ref" "${TDIR}/cur"
assert_true "совпадающие обычные файлы" txn_file_matches "${TDIR}/ref" "${TDIR}/cur"
printf 'b\n' >"${TDIR}/cur"
assert_false "разное содержимое" txn_file_matches "${TDIR}/ref" "${TDIR}/cur"
ln -s ref "${TDIR}/link1"
ln -s ref "${TDIR}/link2"
assert_true "совпадающие симлинки" txn_file_matches "${TDIR}/link1" "${TDIR}/link2"
ln -sf other "${TDIR}/link2"
assert_false "разные цели симлинков" txn_file_matches "${TDIR}/link1" "${TDIR}/link2"
assert_false "файл против симлинка" txn_file_matches "${TDIR}/ref" "${TDIR}/link1"
assert_false "отсутствующий файл" txn_file_matches "${TDIR}/absent" "${TDIR}/cur"

t_section "journal_mark_restored: запись маркера в журнал"
MJ="${TDIR}/journal"
printf 'restore\t/usr/local/etc/xray/config.json\t/var/backups/mifa-vpn-basic/install-1/usr/local/etc/xray/config.json\n' >"$MJ"
assert_true "маркер восстановления записан" journal_mark_restored "$MJ" /usr/local/etc/xray/config.json /var/backups/mifa-vpn-basic/install-1/usr/local/etc/xray/config.json
assert_contains "маркер добавлен в журнал" "$(cat "$MJ")" "restored	/usr/local/etc/xray/config.json	/var/backups/mifa-vpn-basic/install-1/usr/local/etc/xray/config.json"

t_section "txn_rollback: успешный, неудачный, повторный откат"
RBDIR="$(mktemp -d)"
RJ="${RBDIR}/journal.inprogress"
rb_out="${RBDIR}/rb.out"
# Вызов txn_rollback с недоступным systemd: daemon-reload не выполняется.
rb_nosystemd() {
  (
    txn_systemd_available() { return 1; }
    txn_rollback "$@"
  ) >"${rb_out}" 2>&1
}
# Успешный откат: пустой журнал.
: >"$RJ"
rb_nosystemd "$RJ"; rc=$?
assert_rc "успешный откат: код 0" 0 "$rc"
assert_contains "успешный откат: сообщение" "$(cat "$rb_out")" "Откат завершён: изменения установщика отменены"
assert_false "успешный откат: журнал удалён" test -e "$RJ"
# Недопустимая запись: откат прерван до изменений, журнал сохранён, код 3.
printf 'exec\t/etc/passwd\t\n' >"$RJ"
TXN_ACTIVE=1
txn_rollback "$RJ" >"${rb_out}" 2>&1; rc=$?
assert_rc "недопустимая запись: код 3" 3 "$rc"
assert_contains "недопустимая запись: прерывание до изменений" "$(cat "$rb_out")" "Откат прерван до изменений системы"
assert_contains "недопустимая запись: журнал сохранён" "$(cat "$rb_out")" "$RJ"
assert_true "недопустимая запись: журнал сохранён" test -e "$RJ"
assert_eq "недопустимая запись: журнал не изменён" "$(printf 'exec\t/etc/passwd\t')" "$(cat "$RJ")"
assert_eq "недопустимая запись: TXN_ACTIVE сброшен" "0" "$TXN_ACTIVE"
# Повторный откат с той же записью: снова код 3, журнал не теряется.
txn_rollback "$RJ" >"${rb_out}" 2>&1; rc=$?
assert_rc "повторный откат: снова код 3" 3 "$rc"
assert_true "повторный откат: журнал сохранён" test -e "$RJ"
# После исправления журнала повторный откат завершается и удаляет журнал.
printf '# исправлено вручную\n' >"$RJ"
rb_nosystemd "$RJ"; rc=$?
assert_rc "повторный откат после исправления: код 0" 0 "$rc"
assert_false "журнал удалён после успешного повтора" test -e "$RJ"

t_section "txn_rollback: ошибка чтения журнала"
mkdir "${RBDIR}/dirjournal"
txn_rollback "${RBDIR}/dirjournal" >"${rb_out}" 2>&1; rc=$?
assert_rc "журнал-каталог: код 3" 3 "$rc"
assert_contains "журнал-каталог: сообщение" "$(cat "$rb_out")" "Не удалось прочитать журнал"
if [[ "$EUID" -ne 0 ]]; then
  : >"$RJ"
  chmod 000 "$RJ"
  txn_rollback "$RJ" >"${rb_out}" 2>&1; rc=$?
  assert_rc "нечитаемый журнал: код 3" 3 "$rc"
  assert_contains "нечитаемый журнал: сообщение" "$(cat "$rb_out")" "Не удалось прочитать журнал"
  chmod 600 "$RJ"
else
  echo "  SKIP  нечитаемый журнал: тест запущен от root (root читает всё)"
fi

t_section "systemctl/userdel/id: подтверждение stop/disable (моки)"
MOCK_DIR="$(mktemp -d)"
STUB_LOG="$(mktemp)"
# Единственный каталог моков: systemctl, userdel и id заменены заглушками.
# Даже при регрессии алгоритма никакая системная операция не выполнится.
make_mocks() { # is-active, UnitFileState, LoadState, daemon-reload rc
  cat >"${MOCK_DIR}/systemctl" <<EOS
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"\${STUB_LOG:-/dev/null}"
case "\$1" in
  is-active) echo "${1}" ;;
  show)
    case "\$*" in
      *LoadState*) echo "${3}" ;;
      *)           echo "${2}" ;;
    esac
    ;;
esac
exit "${4:-0}"
EOS
  cat >"${MOCK_DIR}/userdel" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_LOG:-/dev/null}"
exit 0
EOS
  cat >"${MOCK_DIR}/id" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_LOG:-/dev/null}"
echo 99999
exit 0
EOS
  chmod 0755 "${MOCK_DIR}/systemctl" "${MOCK_DIR}/userdel" "${MOCK_DIR}/id"
}
run_mock() { # функция и аргументы; systemctl/userdel/id - заглушки из MOCK_DIR
  (
    PATH="${MOCK_DIR}:${PATH}"
    export STUB_LOG
    txn_systemd_available() { return 0; }
    "$@"
  ) 2>&1
}
run_mock_nosystemd() { # как run_mock, но systemd недоступен
  (
    PATH="${MOCK_DIR}:${PATH}"
    export STUB_LOG
    txn_systemd_available() { return 1; }
    "$@"
  ) 2>&1
}
# Очистка временных ресурсов по завершении теста.
cleanup_unit_tmp() {
  rm -rf -- "${TDIR:-}" "${RBDIR:-}" "${MOCK_DIR:-}" "${STUB_LOG:-}" 2>/dev/null || true
}
trap cleanup_unit_tmp EXIT
: >"$STUB_LOG"
make_mocks active enabled loaded
out="$(run_mock txn_stop_unit xray.service)"; rc=$?
assert_rc "stop: сервис активен - ошибка" 1 "$rc"
assert_contains "stop: предупреждение" "$out" "Не удалось подтвердить остановку xray.service"
assert_contains "stop: systemctl stop вызван" "$(cat "$STUB_LOG")" "stop xray.service"
: >"$STUB_LOG"
make_mocks active enabled loaded
out="$(run_mock txn_disable_unit xray.service)"; rc=$?
assert_rc "disable: unit включён - ошибка" 1 "$rc"
assert_contains "disable: предупреждение" "$out" "Не удалось подтвердить отключение xray.service"
assert_contains "disable: systemctl disable вызван" "$(cat "$STUB_LOG")" "disable xray.service"
make_mocks unknown "" loaded
out="$(run_mock txn_stop_unit xray.service)"; rc=$?
assert_rc "stop: неизвестное состояние - ошибка" 1 "$rc"
make_mocks unknown "" loaded
out="$(run_mock txn_disable_unit xray.service)"; rc=$?
assert_rc "disable: неизвестное состояние - ошибка" 1 "$rc"
make_mocks unknown "" not-found
out="$(run_mock txn_stop_unit xray.service)"; rc=$?
assert_rc "stop: unit отсутствует - не ошибка" 0 "$rc"
make_mocks unknown "" not-found
out="$(run_mock txn_disable_unit xray.service)"; rc=$?
assert_rc "disable: unit отсутствует - не ошибка" 0 "$rc"
make_mocks inactive disabled loaded
out="$(run_mock txn_stop_unit xray.service)"; rc=$?
assert_rc "stop: сервис остановлен - успех" 0 "$rc"
make_mocks inactive disabled loaded
out="$(run_mock txn_disable_unit xray.service)"; rc=$?
assert_rc "disable: unit отключён - успех" 0 "$rc"

t_section "txn_rollback: systemd недоступен при наличии stop"
printf '%s\nrestore\t/var/lib/mifa-vpn-basic/manifest\t/var/backups/mifa-vpn-basic/install-1/var/lib/mifa-vpn-basic/manifest\nstop\txray.service\t\n' "$JOURNAL_V2_HEADER" >"$RJ"
out="$(run_mock_nosystemd txn_rollback "$RJ")"; rc=$?
assert_rc "systemd недоступен: код 3" 3 "$rc"
assert_contains "systemd недоступен: сообщение" "$out" "systemd недоступен"
assert_contains "systemd недоступен: файлы не тронуты" "$out" "1 действий с файлами не выполнялись"
assert_true "systemd недоступен: журнал сохранён" test -e "$RJ"

t_section "txn_rollback: фаза сервиса до файловых операций"
printf '%s\nrestore\t/var/lib/mifa-vpn-basic/manifest\t/var/backups/mifa-vpn-basic/install-1/var/lib/mifa-vpn-basic/manifest\nstop\txray.service\t\n' "$JOURNAL_V2_HEADER" >"$RJ"
make_mocks active enabled loaded
out="$(run_mock txn_rollback "$RJ")"; rc=$?
assert_rc "stop не подтверждён: код 3" 3 "$rc"
assert_contains "пропуск файловых действий" "$out" "1 действий с файлами не выполнялись"
assert_true "журнал сохранён после блокировки" test -e "$RJ"
# Legacy service records cannot authorize mutation by name alone.
printf 'stop\txray.service\t\n' >"$RJ"
make_mocks inactive disabled loaded
out="$(run_mock txn_rollback "$RJ")"; rc=$?
assert_rc "legacy stop без свидетельства unit: код 3" 3 "$rc"
assert_true "legacy журнал сохранён" test -e "$RJ"
: >"$RJ"
out="$(run_mock txn_rollback "$RJ")"; rc=$?
assert_rc "пустой журнал не требует мутаций службы: код 0" 0 "$rc"
assert_false "журнал удалён после подтверждения" test -e "$RJ"

t_section "txn_rollback: сбой daemon-reload"
: >"$RJ"
make_mocks inactive disabled loaded 1
out="$(
  # This unit test isolates daemon-reload failure after established ownership.
  txn_quiesce_service() { RB_SERVICE_MANAGED=1; return 0; }
  run_mock txn_rollback "$RJ"
)"; rc=$?
assert_rc "daemon-reload ошибка: код 3" 3 "$rc"
assert_contains "daemon-reload сообщение" "$out" "daemon-reload завершился с ошибкой"
assert_true "журнал сохранён при сбое daemon-reload" test -e "$RJ"

t_section "on_exit: код возврата при откате"
out="$(
  (
    trap - EXIT ERR
    TXN_ACTIVE=1
    txn_rollback() { return 3; }
    false
    on_exit
  ) 2>&1
)"; rc=$?
assert_rc "on_exit: незавершённый откат - код 3" 3 "$rc"
assert_contains "on_exit: резервные копии упомянуты" "$out" "резервные копии"
out="$(
  (
    trap - EXIT ERR
    TXN_ACTIVE=1
    txn_rollback() { return 0; }
    false
    on_exit
  ) 2>&1
)"; rc=$?
assert_rc "on_exit: успешный откат сохраняет исходный код" 1 "$rc"

t_section "do_rollback_mode: «нет журнала» против «журнал недоступен»"
out="$(do_rollback_mode "${RBDIR}/absent" 2>&1)"; rc=$?
assert_rc "нет журнала: код 0" 0 "$rc"
out="$(do_rollback_mode "${RBDIR}/dirjournal" 2>&1)"; rc=$?
assert_rc "журнал-каталог: код 3" 3 "$rc"
assert_contains "журнал-каталог: сообщение" "$out" "не является файлом"
printf 'exec\t/etc/passwd\t\n' >"$RJ"
out="$(run_mock_nosystemd do_rollback_mode "$RJ")"; rc=$?
assert_rc "недопустимая запись через do_rollback_mode: код 3" 3 "$rc"
assert_true "журнал сохранён после недопустимой записи" test -e "$RJ"
printf '# исправлено вручную\n' >"$RJ"
out="$(run_mock_nosystemd do_rollback_mode "$RJ")"; rc=$?
assert_rc "повторный вызов после исправления: код 0" 0 "$rc"
assert_false "журнал удалён после успешного повтора" test -e "$RJ"

t_section "port_in_use"
if command -v ss >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  fp="$(free_port)"
  assert_false "свободный порт $fp не занят" port_in_use "$fp"
  lp="$(start_listener "$fp")"
  wait_port "$fp" 5
  assert_true "порт $fp с слушателем занят" port_in_use "$fp"
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
else
  echo "  SKIP  нет ss или python3"
fi

t_section "CLI: отказ до каких-либо действий"
cli() { bash "$INSTALL_SH" "$@" 2>&1; }
out="$(cli --non-interactive --port 0)"; rc=$?
assert_rc "--port 0: код 2" 2 "$rc"; assert_contains "--port 0: сообщение" "$out" "Некорректный порт"
out="$(cli --port 08443 --sni example.com)"; rc=$?
assert_rc "--port 08443 отклонён" 2 "$rc"
out="$(cli --port)"; rc=$?
assert_rc "--port без значения: код 2" 2 "$rc"; assert_contains "--port без значения: сообщение" "$out" "требует значение"
out="$(cli --non-interactive </dev/null)"; rc=$?
assert_rc "без --sni: код 2" 2 "$rc"; assert_contains "без --sni: SNI не выбирается молча" "$out" "не выбирает"
out="$(cli --plan --sni 'bad_domain')"; rc=$?
assert_rc "некорректный SNI" 2 "$rc"
out="$(cli --plan --sni example.com --target 'example.com')"; rc=$?
assert_rc "target без порта" 2 "$rc"
out="$(cli --plan --sni example.com --xray-version v1.8.0)"; rc=$?
assert_rc "--xray-version без SHA256" 2 "$rc"; assert_contains "--xray-version: пояснение" "$out" "без проверки целостности"
out="$(cli --plan --sni example.com --xray-sha256 abc)"; rc=$?
assert_rc "некорректный --xray-sha256" 2 "$rc"
out="$(cli --plan --dry-run --sni example.com)"; rc=$?
assert_rc "два режима сразу" 2 "$rc"
out="$(cli --frobnicate)"; rc=$?
assert_rc "неизвестный аргумент" 2 "$rc"
out="$(cli --help)"; rc=$?
assert_rc "--help" 0 "$rc"; assert_contains "--help описывает --non-interactive" "$out" "--non-interactive"
assert_contains "--help описывает --dry-run" "$out" "--dry-run"
# Установку вызываем только без root: под root это была бы настоящая установка.
if [[ "$EUID" -ne 0 ]]; then
  out="$(cli --sni example.com --non-interactive)"; rc=$?
  assert_rc "установка без root отклонена" 1 "$rc"; assert_contains "сообщение о root" "$out" "sudo"
else
  echo "  SKIP  проверка отказа без root: тест запущен от root"
fi

t_summary
