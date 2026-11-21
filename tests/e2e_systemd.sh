#!/usr/bin/env bash
# Полный сценарий в одноразовом контейнере с systemd (tests/run-docker.sh e2e):
#  - режимы без изменений на чистой системе с проходящим preflight;
#  - установка, проверка сервиса, прав и маскировки REALITY;
#  - подключение настоящим клиентом Xray по ссылке из client.txt (loopback);
#  - блокировка доступа клиентов к localhost и metadata-адресам;
#  - отказ повторной установки без изменения рабочего конфига;
#  - автоматический откат при сбое на каждом шаге и после SIGKILL;
#  - удаление с резервной копией и восстановление прежних ключей.
#
# REALITY-цель герметична: тестовый CA, openssl s_server на 198.51.100.11:443
# (документационный диапазон), домен reality-target.test в /etc/hosts.
# Адрес назначения для трафика клиента - 192.0.0.100: не маршрутизируется в
# интернете и не входит во встроенный список блокировки freedom в Xray v26.
# Это не внешняя E2E-проверка: клиент и сервер работают в одном контейнере.
set -uo pipefail
T_NAME="e2e"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
require_disposable
[[ -d /run/systemd/system ]] || { echo "Нужен контейнер с systemd" >&2; exit 2; }

W="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  if [[ -e /usr/bin/python3.mifa-masked ]]; then
    mv -f /usr/bin/python3.mifa-masked /usr/bin/python3
  fi
}
trap cleanup EXIT

SNI="reality-target.test"
TARGET_IP="198.51.100.11"
DEST_IP="192.0.0.100"
PORT=8443
CLIENT_FILE=/var/lib/mifa-vpn-basic/client.txt
MARKER="mifa-basic-e2e-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"

abort() {
  t_fail "$1"
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed -n '1,80p' | sed 's/^/        > /'
  t_summary
  exit 1
}

# --- Окружение ----------------------------------------------------------------
t_section "Подготовка герметичной REALITY-цели"
ip addr add "${TARGET_IP}/32" dev lo 2>/dev/null
ip addr add "${DEST_IP}/32" dev lo 2>/dev/null
make_test_ca "$W"
make_cert "$W" target "$SNI"
cp "${W}/ca.pem" /usr/local/share/ca-certificates/mifa-basic-test-ca.crt
update-ca-certificates >/dev/null 2>&1
grep -q "$SNI" /etc/hosts || echo "${TARGET_IP} ${SNI}" >>/etc/hosts
PIDS+=("$(start_tls_target "$TARGET_IP" 443 "${W}/target")")
mkdir -p "${W}/www"
echo "$MARKER" >"${W}/www/marker.txt"
python3 -m http.server --bind "$DEST_IP" 8080 --directory "${W}/www" >/dev/null 2>&1 &
PIDS+=("$!")
python3 -m http.server --bind 127.0.0.1 8081 --directory "${W}/www" >/dev/null 2>&1 &
PIDS+=("$!")
if ! { wait_port 443 5 && wait_port 8080 5 && wait_port 8081 5; }; then
  abort "тестовые серверы не запустились"
fi
assert_eq "контроль: прямой доступ к ${DEST_IP}:8080" "$MARKER" "$(curl -sS --max-time 5 "http://${DEST_IP}:8080/marker.txt")"
assert_eq "контроль: прямой доступ к 127.0.0.1:8081" "$MARKER" "$(curl -sS --max-time 5 "http://127.0.0.1:8081/marker.txt")"

# Архив Xray: первая установка проверяет загрузку установщиком (если не задан
# MIFA_TEST_XRAY_ZIP), остальные используют один заранее проверенный архив.
PINNED_SHA="$(sed -n 's/^readonly XRAY_PINNED_SHA256_64="\([0-9a-f]*\)"/\1/p' "$INSTALL_SH")"
PINNED_VER="$(sed -n 's/^readonly XRAY_PINNED_VERSION="\(v[0-9.]*\)"/\1/p' "$INSTALL_SH")"
FIRST_SRC=()
if [[ -n "${MIFA_TEST_XRAY_ZIP:-}" ]]; then
  FIRST_SRC=(--xray-zip "$MIFA_TEST_XRAY_ZIP")
  ZIP="$MIFA_TEST_XRAY_ZIP"
elif [[ -n "${MIFA_TEST_XRAY_ZIP_AUX:-}" ]]; then
  ZIP="$MIFA_TEST_XRAY_ZIP_AUX"
else
  ZIP="${W}/xray.zip"
  curl -fsSL --proto '=https' --retry 3 --max-time 600 -o "$ZIP" \
    "https://github.com/XTLS/Xray-core/releases/download/${PINNED_VER}/Xray-linux-64.zip" \
    || abort "не удалось скачать архив Xray для повторных сценариев"
fi
assert_eq "архив для повторных сценариев совпадает с закреплённым SHA256" "$PINNED_SHA" "$(sha256sum "$ZIP" | awk '{print $1}')"
SRC=(--xray-zip "$ZIP")
BASE=(--non-interactive --sni "$SNI" --port "$PORT" --server-address 127.0.0.1 --no-print-secrets)

assert_clean_host() {
  local p
  for p in /usr/local/bin/xray /usr/local/etc/xray /etc/systemd/system/xray.service /var/lib/mifa-vpn-basic; do
    assert_false "$1: нет $p" test -e "$p"
  done
  assert_false "$1: нет пользователя xray" user_exists xray
  assert_eq "$1: unit xray.service не загружен" "not-found" "$(systemctl show -p LoadState --value xray.service)"
  assert_eq "$1: порт ${PORT} свободен" "" "$(ss -Htln "sport = :${PORT}")"
}

cval() { sed -n "s/^$1=//p" "${2:-$CLIENT_FILE}"; }

# Разбирает vless:// ссылку в массив U.
declare -A U
parse_vless_uri() {
  local uri="$1" q kv
  local re='^vless://([0-9a-f-]+)@(\[[0-9a-fA-F:.]+\]|[^:/?#]+):([0-9]+)\?([^#]*)#(.*)$'
  U=()
  [[ "$uri" =~ $re ]] || return 1
  U[uuid]="${BASH_REMATCH[1]}"
  U[host]="${BASH_REMATCH[2]}"
  U[port]="${BASH_REMATCH[3]}"
  q="${BASH_REMATCH[4]}"
  U[name]="${BASH_REMATCH[5]}"
  local IFS='&'
  for kv in $q; do
    U["q_${kv%%=*}"]="${kv#*=}"
  done
}

# Поднимает клиент Xray по ссылке и делает запрос через туннель.
# client_fetch FILE URL [key=value ...] -> печатает ответ, код curl
client_fetch() {
  local file="$1" url="$2" sp cfg pid out rc kv
  shift 2
  parse_vless_uri "$(cval vless_uri "$file")" || { echo "PARSE_ERROR"; return 90; }
  for kv in "$@"; do U["${kv%%=*}"]="${kv#*=}"; done
  sp="$(free_port)"
  cfg="${W}/client-${sp}.json"
  cat >"$cfg" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": ${sp}, "protocol": "socks", "settings": {"udp": false}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "${U[host]}", "port": ${U[port]},
      "users": [{"id": "${U[uuid]}", "encryption": "${U[q_encryption]}", "flow": "${U[q_flow]}"}]}]},
    "streamSettings": {"network": "${U[q_type]}", "security": "${U[q_security]}",
      "realitySettings": {"serverName": "${U[q_sni]}", "fingerprint": "${U[q_fp]}",
        "publicKey": "${U[q_pbk]}", "shortId": "${U[q_sid]}"}}
  }]
}
EOF
  /usr/local/bin/xray run -config "$cfg" >"${cfg}.log" 2>&1 &
  pid=$!
  if ! wait_port "$sp" 10; then
    kill "$pid" 2>/dev/null
    echo "CLIENT_DID_NOT_START: $(tail -n 3 "${cfg}.log")"
    return 91
  fi
  out="$(curl -sS --max-time "${FETCH_TIMEOUT:-10}" --socks5-hostname "127.0.0.1:${sp}" "$url" 2>&1)"
  rc=$?
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  printf '%s' "$out"
  return "$rc"
}

# --- Режимы без изменений на чистой системе ----------------------------------
t_section "preflight/plan/dry-run на чистой системе с systemd"
out="$(bash "$INSTALL_SH" --preflight "${BASE[@]}" "${SRC[@]}" 2>&1)"; rc=$?
assert_rc "preflight проходит (код 0)" 0 "$rc"
assert_contains "REALITY-цель подтверждена" "$out" "TLS 1.3, X25519, HTTP/2 и сертификат для ${SNI} подтверждены"
[[ "$rc" == 0 ]] || abort "preflight не прошёл на чистой системе" "$out"
if MIFA_NOCHANGE_ARGS="${BASE[*]} ${SRC[*]}" MIFA_NOCHANGE_EXPECT_RC=0 \
   MIFA_SNAPSHOT_PRUNE="/var/log/journal /var/lib/systemd" MIFA_TEST_XRAY_ZIP="" \
   bash "${TESTS_DIR}/nochange.sh" >"${W}/nochange.log" 2>&1; then
  t_pass "nochange.sh: preflight, plan и dry-run не меняют систему (код 0)"
else
  t_fail "nochange.sh в контейнере с systemd"
  sed 's/^/        > /' "${W}/nochange.log" | sed -n '1,60p'
fi

# --- Установка ---------------------------------------------------------------
t_section "Установка на чистую систему"
out="$(bash "$INSTALL_SH" "${BASE[@]}" "${FIRST_SRC[@]}" 2>&1)"; rc=$?
assert_rc "установка: код 0" 0 "$rc"
[[ "$rc" == 0 ]] || abort "установка не удалась" "$out"
assert_contains "установка завершена" "$out" "Установка завершена"
if (( ${#FIRST_SRC[@]} == 0 )); then
  assert_contains "загрузка: .dgst релиза сверен" "$out" ".dgst релиза совпадает"
fi
assert_contains "SHA256 подтверждён" "$out" "SHA256 архива Xray подтверждён: ${PINNED_SHA}"
assert_contains "маскировка REALITY проверена установщиком" "$out" "отвечает настоящий сертификат ${SNI}"
UUID="$(cval uuid)"; PBK="$(cval public_key)"; SID="$(cval short_id)"
assert_true "UUID в client.txt" test -n "$UUID"
assert_not_contains "--no-print-secrets: UUID не напечатан" "$out" "$UUID"
assert_not_contains "--no-print-secrets: ключ не напечатан" "$out" "$PBK"
assert_not_contains "--no-print-secrets: shortId не напечатан" "$out" "$SID"
assert_not_contains "закрытый ключ не напечатан" "$out" "$(sed -n 's/.*"privateKey": "\([^"]*\)".*/\1/p' /usr/local/etc/xray/config.json)"

t_section "Сервис, права и изоляция"
assert_eq "xray.service активен" "active" "$(systemctl is-active xray.service)"
assert_eq "xray.service включён" "enabled" "$(systemctl is-enabled xray.service)"
assert_contains "порт ${PORT} слушает xray" "$(ss -Htlnp "sport = :${PORT}")" '"xray"'
meta() { stat -c '%a %U %G' "$1"; }
assert_eq "права ${XRAY_BIN:-/usr/local/bin/xray}" "755 root root" "$(meta /usr/local/bin/xray)"
assert_eq "права /usr/local/etc/xray" "750 root xray" "$(meta /usr/local/etc/xray)"
assert_eq "права config.json" "640 root xray" "$(meta /usr/local/etc/xray/config.json)"
assert_eq "права xray.service" "644 root root" "$(meta /etc/systemd/system/xray.service)"
assert_eq "права /var/lib/mifa-vpn-basic" "700 root root" "$(meta /var/lib/mifa-vpn-basic)"
assert_eq "права client.txt" "600 root root" "$(meta "$CLIENT_FILE")"
assert_eq "права manifest" "600 root root" "$(meta /var/lib/mifa-vpn-basic/manifest)"
assert_false "журнал транзакции удалён" test -e /var/lib/mifa-vpn-basic/journal.inprogress
main_pid="$(systemctl show -p MainPID --value xray.service)"
assert_eq "процесс работает от пользователя xray" "xray" "$(stat -c %U "/proc/${main_pid}")"
assert_eq "NoNewPrivileges" "yes" "$(systemctl show -p NoNewPrivileges --value xray.service)"
assert_eq "оболочка пользователя xray" "/usr/sbin/nologin" "$(getent passwd xray | cut -d: -f7)"
assert_true "xray run -test от имени xray" runuser -u xray -- /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
assert_eq "версия установленного Xray" "Xray ${PINNED_VER#v}" "$(/usr/local/bin/xray version | head -n1 | cut -d' ' -f1-2)"
probe="$(openssl s_client -connect "127.0.0.1:${PORT}" -servername "$SNI" -verify_hostname "$SNI" </dev/null 2>&1)"
assert_contains "неаутентифицированный TLS получает сертификат цели" "$probe" "Verify return code: 0 (ok)"
# OpenSSL 3.0 печатает "CN = x", OpenSSL 3.5 (Ubuntu 26.04) - "CN=x".
assert_true "сертификат цели: CN" grep -Eq "CN ?= ?${SNI//./\\.}" <<<"$probe"

t_section "Ссылка клиента и подключение настоящим клиентом Xray"
parse_vless_uri "$(cval vless_uri)"
assert_eq "URI: uuid" "$UUID" "${U[uuid]:-}"
assert_eq "URI: host" "127.0.0.1" "${U[host]:-}"
assert_eq "URI: port" "$PORT" "${U[port]:-}"
assert_eq "URI: encryption" "none" "${U[q_encryption]:-}"
assert_eq "URI: flow" "xtls-rprx-vision" "${U[q_flow]:-}"
assert_eq "URI: security" "reality" "${U[q_security]:-}"
assert_eq "URI: sni" "$SNI" "${U[q_sni]:-}"
assert_eq "URI: fp" "chrome" "${U[q_fp]:-}"
assert_eq "URI: pbk" "$PBK" "${U[q_pbk]:-}"
assert_eq "URI: sid" "$SID" "${U[q_sid]:-}"
assert_eq "URI: type" "tcp" "${U[q_type]:-}"
res="$(client_fetch "$CLIENT_FILE" "http://${DEST_IP}:8080/marker.txt")"; rc=$?
assert_rc "запрос через туннель: код curl" 0 "$rc"
assert_eq "запрос через туннель: ответ" "$MARKER" "$res"
res="$(FETCH_TIMEOUT=4 client_fetch "$CLIENT_FILE" "http://127.0.0.1:8081/marker.txt")"; rc=$?
assert_rc_nonzero "доступ клиента к localhost сервера заблокирован" "$rc"
assert_not_contains "localhost: ответ не получен" "$res" "$MARKER"
res="$(FETCH_TIMEOUT=4 client_fetch "$CLIENT_FILE" "http://169.254.169.254/latest/meta-data/")"; rc=$?
assert_rc_nonzero "доступ клиента к metadata-адресу заблокирован" "$rc"
res="$(FETCH_TIMEOUT=4 client_fetch "$CLIENT_FILE" "http://localhost:8081/marker.txt")"; rc=$?
assert_not_contains "доступ клиента к localhost по имени заблокирован" "$res" "$MARKER"
res="$(FETCH_TIMEOUT=4 client_fetch "$CLIENT_FILE" "http://${DEST_IP}:8080/marker.txt" uuid=00000000-0000-4000-8000-000000000000)"; rc=$?
assert_rc_nonzero "чужой UUID не проходит" "$rc"
res="$(FETCH_TIMEOUT=4 client_fetch "$CLIENT_FILE" "http://${DEST_IP}:8080/marker.txt" q_sid=ffffffffffffffff)"; rc=$?
assert_rc_nonzero "чужой shortId не проходит" "$rc"

t_section "Повторная установка не трогает рабочий конфиг"
cfg_sha="$(sha256sum /usr/local/etc/xray/config.json)"
client_sha="$(sha256sum "$CLIENT_FILE")"
for extra in "" "--port 9443"; do
  # shellcheck disable=SC2086
  out="$(bash "$INSTALL_SH" "${BASE[@]}" "${SRC[@]}" $extra 2>&1)"; rc=$?
  assert_rc_nonzero "повторная установка ${extra:-с теми же параметрами} отклонена" "$rc"
  assert_contains "повторная установка: сообщение" "$out" "Basic уже установлен"
done
assert_eq "config.json не изменён" "$cfg_sha" "$(sha256sum /usr/local/etc/xray/config.json)"
assert_eq "client.txt не изменён" "$client_sha" "$(sha256sum "$CLIENT_FILE")"
assert_eq "сервис не перезапускался" "$main_pid" "$(systemctl show -p MainPID --value xray.service)"

t_section "Перезапуск сервиса"
systemctl restart xray.service
wait_port "$PORT" 15
assert_eq "после restart активен" "active" "$(systemctl is-active xray.service)"
res="$(client_fetch "$CLIENT_FILE" "http://${DEST_IP}:8080/marker.txt")"
assert_eq "после restart клиент подключается" "$MARKER" "$res"

t_section "Удаление с резервной копией и восстановление прежних ключей"
cp "$CLIENT_FILE" "${W}/client-before.txt"
cfg_sha_only="$(sha256sum /usr/local/etc/xray/config.json | awk '{print $1}')"
out="$(bash "$UNINSTALL_SH" --yes 2>&1)"; rc=$?
assert_rc "uninstall: код 0" 0 "$rc"
BK="$(sed -n 's/^Резервная копия конфига и данных клиента: //p' <<<"$out")"
assert_true "каталог резервной копии существует" test -d "$BK"
assert_eq "config.json в резервной копии совпадает" "$cfg_sha_only" "$(sha256sum "${BK}/usr/local/etc/xray/config.json" | awk '{print $1}')"
assert_eq "права резервной копии" "700" "$(stat -c %a "$BK")"
assert_clean_host "после uninstall"
out="$(bash "$INSTALL_SH" "${BASE[@]}" "${SRC[@]}" 2>&1)"; rc=$?
assert_rc "переустановка после uninstall: код 0" 0 "$rc"
assert_false "переустановка создаёт новые ключи" test "$(cval uuid)" == "$UUID"
# Процедура из docs/RECOVERY.md: вернуть прежний конфиг и данные клиента.
systemctl stop xray.service
install -m 0640 -o root -g xray "${BK}/usr/local/etc/xray/config.json" /usr/local/etc/xray/config.json
install -m 0600 -o root -g root "${BK}/var/lib/mifa-vpn-basic/client.txt" "$CLIENT_FILE"
assert_true "восстановленный конфиг проходит xray run -test" runuser -u xray -- /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
systemctl start xray.service
wait_port "$PORT" 15
res="$(client_fetch "${W}/client-before.txt" "http://${DEST_IP}:8080/marker.txt")"
assert_eq "прежняя ссылка клиента снова работает" "$MARKER" "$res"
out="$(bash "$UNINSTALL_SH" --yes 2>&1)"; rc=$?
assert_rc "повторное удаление: код 0" 0 "$rc"
assert_clean_host "после повторного удаления"
out="$(bash "$UNINSTALL_SH" --yes 2>&1)"; rc=$?
assert_rc "удаление на чистой системе: код 0" 0 "$rc"
assert_contains "удаление на чистой системе: сообщение" "$out" "удалять нечего"

t_section "Автоматический откат при сбое на каждом шаге"
for step in after_user after_binary after_config after_unit after_enable after_start before_commit; do
  out="$(MIFA_BASIC_TEST_MODE=1 MIFA_BASIC_TEST_FAIL_AT="$step" bash "$INSTALL_SH" "${BASE[@]}" "${SRC[@]}" 2>&1)"; rc=$?
  assert_rc "${step}: установка прервана" 97 "$rc"
  assert_contains "${step}: откат выполнен" "$out" "Откат завершён: изменения установщика отменены"
  assert_clean_host "$step"
done

t_section "Откат восстанавливает ранее существовавший файл из резервной копии"
install -d -m 700 /var/lib/mifa-vpn-basic
printf 'mifa_basic_version=stale\n' >/var/lib/mifa-vpn-basic/manifest
chmod 600 /var/lib/mifa-vpn-basic/manifest
stale_sha="$(sha256sum /var/lib/mifa-vpn-basic/manifest | awk '{print $1}')"
out="$(MIFA_BASIC_TEST_MODE=1 MIFA_BASIC_TEST_FAIL_AT=before_commit bash "$INSTALL_SH" "${BASE[@]}" "${SRC[@]}" 2>&1)"; rc=$?
assert_rc "сбой перед фиксацией" 97 "$rc"
assert_contains "файл сохранён перед заменой" "$out" "Резервная копия: /var/lib/mifa-vpn-basic/manifest"
assert_contains "файл восстановлен при откате" "$out" "Восстановлен /var/lib/mifa-vpn-basic/manifest"
assert_eq "прежний манифест восстановлен байт в байт" "$stale_sha" "$(sha256sum /var/lib/mifa-vpn-basic/manifest | awk '{print $1}')"
assert_eq "права восстановленного файла" "600 root root" "$(stat -c '%a %U %G' /var/lib/mifa-vpn-basic/manifest)"
assert_true "существовавший каталог состояния не удалён" test -d /var/lib/mifa-vpn-basic
assert_false "бинарник удалён" test -e /usr/local/bin/xray
assert_false "пользователь xray удалён" user_exists xray
assert_eq "unit не загружен" "not-found" "$(systemctl show -p LoadState --value xray.service)"
rm -rf /var/lib/mifa-vpn-basic /var/backups/mifa-vpn-basic
assert_clean_host "после очистки"

t_section "Внедрение сбоя без MIFA_BASIC_TEST_MODE не действует"
out="$(MIFA_BASIC_TEST_FAIL_AT=after_user bash "$INSTALL_SH" "${BASE[@]}" "${SRC[@]}" 2>&1)"; rc=$?
assert_rc "установка проходит" 0 "$rc"
bash "$UNINSTALL_SH" --yes >/dev/null 2>&1
assert_clean_host "после удаления"

t_section "Прерывание SIGKILL и --rollback"
out="$(MIFA_BASIC_TEST_MODE=1 MIFA_BASIC_TEST_FAIL_AT=after_enable:kill bash "$INSTALL_SH" "${BASE[@]}" "${SRC[@]}" 2>&1)"; rc=$?
assert_rc "процесс убит SIGKILL" 137 "$rc"
assert_true "журнал остался" test -f /var/lib/mifa-vpn-basic/journal.inprogress
assert_true "частичная установка осталась" test -e /usr/local/bin/xray
out="$(bash "$INSTALL_SH" --preflight "${BASE[@]}" "${SRC[@]}" 2>&1)"; rc=$?
assert_rc "preflight после прерывания: код 1" 1 "$rc"
assert_contains "preflight подсказывает --rollback" "$out" "install.sh --rollback"
out="$(bash "$INSTALL_SH" "${BASE[@]}" "${SRC[@]}" 2>&1)"; rc=$?
assert_rc_nonzero "установка поверх прерванной отклонена" "$rc"
assert_true "журнал не тронут отказом" test -f /var/lib/mifa-vpn-basic/journal.inprogress
out="$(bash "$INSTALL_SH" --rollback 2>&1)"; rc=$?
assert_rc "--rollback: код 0" 0 "$rc"
assert_clean_host "после --rollback"
out="$(bash "$INSTALL_SH" "${BASE[@]}" "${SRC[@]}" 2>&1)"; rc=$?
assert_rc "установка после --rollback: код 0" 0 "$rc"
res="$(client_fetch "$CLIENT_FILE" "http://${DEST_IP}:8080/marker.txt")"
assert_eq "клиент подключается после восстановления" "$MARKER" "$res"
bash "$UNINSTALL_SH" --yes >/dev/null 2>&1
assert_clean_host "после удаления"

t_section "Незавершённый откат: код 3, журнал и резервные копии сохранены"
out="$(MIFA_BASIC_TEST_MODE=1 MIFA_BASIC_TEST_FAIL_AT=after_enable:kill bash "$INSTALL_SH" "${BASE[@]}" "${SRC[@]}" 2>&1)"; rc=$?
assert_rc "установка убита SIGKILL" 137 "$rc"
assert_true "журнал создан" test -f /var/lib/mifa-vpn-basic/journal.inprogress
assert_true "каталог конфига создан" test -d /usr/local/etc/xray
printf 'keep\n' >/usr/local/etc/xray/keep-me.txt
out="$(bash "$INSTALL_SH" --rollback 2>&1)"; rc=$?
assert_rc "--rollback при неполном откате: код 3" 3 "$rc"
assert_contains "журнал сохранён" "$out" "журнал /var/lib/mifa-vpn-basic/journal.inprogress и резервные копии"
assert_contains "каталог не пуст" "$out" "не пуст"
assert_true "журнал сохранён" test -f /var/lib/mifa-vpn-basic/journal.inprogress
assert_true "посторонний файл не удалён" test -e /usr/local/etc/xray/keep-me.txt
assert_false "сервис не активен" systemctl is-active --quiet xray.service
assert_false "бинарник удалён" test -e /usr/local/bin/xray
out="$(bash "$INSTALL_SH" --rollback 2>&1)"; rc=$?
assert_rc "повторный --rollback без исправления: снова код 3" 3 "$rc"
assert_true "журнал по-прежнему сохранён" test -f /var/lib/mifa-vpn-basic/journal.inprogress
rm -f /usr/local/etc/xray/keep-me.txt
out="$(bash "$INSTALL_SH" --rollback 2>&1)"; rc=$?
assert_rc "повторный --rollback после исправления: код 0" 0 "$rc"
assert_false "журнал удалён" test -e /var/lib/mifa-vpn-basic/journal.inprogress
assert_clean_host "после повторного --rollback"

t_section "Частичный restore: маркер, повтор и сохранение данных"
install -d -m 700 /var/lib/mifa-vpn-basic
printf 'mifa_basic_version=stale\n' >/var/lib/mifa-vpn-basic/manifest
chmod 600 /var/lib/mifa-vpn-basic/manifest
stale_sha_retry="$(sha256sum /var/lib/mifa-vpn-basic/manifest | awk '{print $1}')"
out="$(MIFA_BASIC_TEST_MODE=1 MIFA_BASIC_TEST_FAIL_AT=before_commit:kill bash "$INSTALL_SH" "${BASE[@]}" "${SRC[@]}" 2>&1)"; rc=$?
assert_rc "поздний сбой (kill после старта): код 137" 137 "$rc"
assert_true "журнал остался" test -f /var/lib/mifa-vpn-basic/journal.inprogress
printf 'keep\n' >/usr/local/etc/xray/keep-me.txt
out="$(bash "$INSTALL_SH" --rollback 2>&1)"; rc=$?
assert_rc "первый откат с restore и rmdir-ошибкой: код 3" 3 "$rc"
assert_contains "restore выполнен" "$out" "Восстановлен /var/lib/mifa-vpn-basic/manifest"
assert_contains "журнал сохранён" "$out" "журнал /var/lib/mifa-vpn-basic/journal.inprogress и резервные копии"
assert_true "журнал содержит маркер restored" grep -q $'restored\t/var/lib/mifa-vpn-basic/manifest\t' /var/lib/mifa-vpn-basic/journal.inprogress
assert_eq "манифест восстановлен" "$stale_sha_retry" "$(sha256sum /var/lib/mifa-vpn-basic/manifest | awk '{print $1}')"
assert_false "client.txt удалён" test -e /var/lib/mifa-vpn-basic/client.txt
out="$(bash "$INSTALL_SH" --rollback 2>&1)"; rc=$?
assert_rc "повторный откат с маркером restore: код 3" 3 "$rc"
assert_contains "restore не повторяется" "$out" "Уже восстановлен /var/lib/mifa-vpn-basic/manifest"
assert_eq "манифест не перезаписан повторно" "$stale_sha_retry" "$(sha256sum /var/lib/mifa-vpn-basic/manifest | awk '{print $1}')"
assert_true "журнал по-прежнему сохранён" test -f /var/lib/mifa-vpn-basic/journal.inprogress
rm -f /usr/local/etc/xray/keep-me.txt
out="$(bash "$INSTALL_SH" --rollback 2>&1)"; rc=$?
assert_rc "повторный откат после устранения причины: код 0" 0 "$rc"
assert_eq "манифест восстановлен байт в байт" "$stale_sha_retry" "$(sha256sum /var/lib/mifa-vpn-basic/manifest | awk '{print $1}')"
rm -rf /var/lib/mifa-vpn-basic /var/backups/mifa-vpn-basic
assert_clean_host "после очистки (частичный restore)"

if [[ "${MIFA_E2E_SKIP_APT:-0}" != "1" ]]; then
  t_section "Нет unzip и python3: установщик ставит unzip через apt"
  if command -v unzip >/dev/null 2>&1; then
    echo "  SKIP  unzip уже установлен"
  else
    mv /usr/bin/python3 /usr/bin/python3.mifa-masked
    out="$(bash "$INSTALL_SH" "${BASE[@]}" "${SRC[@]}" 2>&1)"; rc=$?
    mv -f /usr/bin/python3.mifa-masked /usr/bin/python3
    assert_rc "установка с apt-get install unzip: код 0" 0 "$rc"
    assert_contains "unzip установлен" "$out" "Пакет unzip установлен"
    bash "$UNINSTALL_SH" --yes >/dev/null 2>&1
    assert_clean_host "после удаления"
  fi
fi

if [[ -n "${MIFA_E2E_PUBLIC_SNI:-}" ]]; then
  t_section "Публичная REALITY-цель ${MIFA_E2E_PUBLIC_SNI} (нужен интернет)"
  # Порт 443 в контейнере занят герметичной целью, поэтому используется ${PORT}.
  PUB=(--non-interactive --sni "$MIFA_E2E_PUBLIC_SNI" --port "$PORT" --server-address 127.0.0.1 --no-print-secrets)
  out="$(bash "$INSTALL_SH" "${PUB[@]}" "${SRC[@]}" 2>&1)"; rc=$?
  assert_rc "установка с публичной целью: код 0" 0 "$rc"
  if [[ "$rc" == 0 ]]; then
    assert_contains "публичная цель: маскировка проверена" "$out" "отвечает настоящий сертификат ${MIFA_E2E_PUBLIC_SNI}"
    res="$(client_fetch "$CLIENT_FILE" "https://www.google.com/generate_204")"; rc=$?
    assert_rc "HTTPS-запрос в интернет через туннель" 0 "$rc"
  else
    printf '%s\n' "$out" | sed -n '1,40p' | sed 's/^/        > /'
  fi
  bash "$UNINSTALL_SH" --yes >/dev/null 2>&1
  assert_clean_host "после удаления (публичная цель)"
fi

t_summary
