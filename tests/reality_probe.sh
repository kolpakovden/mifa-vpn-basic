#!/usr/bin/env bash
# Проверка reality_tls_check против локального openssl s_server с разными
# свойствами. Не меняет систему: тестовый CA передаётся через SSL_CERT_FILE,
# серверы слушают 127.0.0.1 и завершаются в конце.
set -uo pipefail
T_NAME="reality_probe"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

MIFA_BASIC_LIB=1
# shellcheck source=install.sh
. "$INSTALL_SH"
set +e +E
trap - ERR

D="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$D"
}
trap cleanup EXIT

make_test_ca "$D"
make_cert "$D" good good.test
make_cert "$D" other other.test
make_cert "$D" self good.test self
export SSL_CERT_FILE="${D}/ca.pem"
export MIFA_PROBE_TIMEOUT=5

PORT_BASE="$(free_port)"
n=0
scenario() { # имя, ожидание (ok|fail), подстрока ошибки, сертификат, опции s_server...
  local name="$1" expect="$2" needle="$3" cert="$4" port pid rc
  shift 4
  port=$((PORT_BASE + n))
  n=$((n + 1))
  pid="$(start_tls_server 127.0.0.1 "$port" "${D}/${cert}" "$@")"
  PIDS+=("$pid")
  if ! wait_port "$port" 5; then
    t_fail "${name}: тестовый сервер не запустился"
    return
  fi
  reality_tls_check 127.0.0.1 "$port" good.test
  rc=$?
  if [[ "$expect" == "ok" ]]; then
    assert_rc "${name}: цель принята" 0 "$rc"
  else
    assert_rc_nonzero "${name}: цель отклонена" "$rc"
    assert_contains "${name}: причина" "$REALITY_ERROR" "$needle"
  fi
  kill "$pid" 2>/dev/null
}

t_section "reality_tls_check ($(openssl version))"
scenario "TLS 1.3 + h2 + X25519 + верный сертификат" ok "" good -alpn h2
scenario "нет HTTP/2" fail "HTTP/2" good
scenario "только TLS 1.2" fail "TLS 1.3" good -no_tls1_3 -alpn h2
scenario "нет X25519 (только P-256)" fail "X25519" good -groups P-256 -alpn h2
scenario "сертификат на другой домен" fail "сертификат" other -alpn h2
scenario "самоподписанный сертификат" fail "сертификат" self -alpn h2

dead_port=$((PORT_BASE + n + 5))
reality_tls_check 127.0.0.1 "$dead_port" good.test
rc=$?
assert_rc_nonzero "нет слушателя: цель отклонена" "$rc"
assert_contains "нет слушателя: причина" "$REALITY_ERROR" "соединение"

t_section "SNI в тесте не подменяется адресом"
port=$((PORT_BASE + n))
pid="$(start_tls_server 127.0.0.1 "$port" "${D}/good" -alpn h2)"
PIDS+=("$pid")
wait_port "$port" 5
reality_tls_check 127.0.0.1 "$port" other.test
rc=$?
assert_rc_nonzero "SNI other.test к серверу good.test отклонён" "$rc"

t_summary
