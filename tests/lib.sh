# shellcheck shell=bash
# Общие функции тестов MIFA VPN Basic.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
export INSTALL_SH="${REPO_DIR}/install.sh"
export UNINSTALL_SH="${REPO_DIR}/uninstall.sh"

T_PASS=0
T_FAIL=0
T_NAME="${T_NAME:-tests}"

t_pass() { T_PASS=$((T_PASS + 1)); printf '  PASS  %s\n' "$*"; }
t_fail() { T_FAIL=$((T_FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
t_section() { printf '\n== %s ==\n' "$*"; }

assert_true() { # описание, команда...
  local d="$1"
  shift
  if "$@"; then t_pass "$d"; else t_fail "$d"; fi
}

assert_false() {
  local d="$1"
  shift
  if "$@"; then t_fail "$d"; else t_pass "$d"; fi
}

assert_eq() { # описание, ожидаемое, фактическое
  if [[ "$2" == "$3" ]]; then
    t_pass "$1"
  else
    t_fail "$1"
    printf '        ожидалось: %s\n        получено:  %s\n' "$2" "$3"
  fi
}

assert_contains() { # описание, текст, подстрока
  if [[ "$2" == *"$3"* ]]; then
    t_pass "$1"
  else
    t_fail "$1"
    printf '        нет подстроки: %s\n' "$3"
    printf '%s\n' "$2" | sed -n '1,40p' | sed 's/^/        | /'
  fi
}

assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then
    t_pass "$1"
  else
    t_fail "$1"
    printf '        найдена запрещённая подстрока: %s\n' "$3"
  fi
}

assert_rc() { # описание, ожидаемый код, фактический код
  if [[ "$2" == "$3" ]]; then
    t_pass "$1"
  else
    t_fail "$1 (код ${3}, ожидался ${2})"
  fi
}

assert_rc_nonzero() {
  if [[ "$2" != "0" ]]; then
    t_pass "$1"
  else
    t_fail "$1 (код 0, ожидалась ошибка)"
  fi
}

t_summary() {
  printf '\n%s: пройдено %d, ошибок %d\n' "$T_NAME" "$T_PASS" "$T_FAIL"
  (( T_FAIL == 0 ))
}

# Тесты, меняющие систему, выполняются только в одноразовом контейнере.
require_disposable() {
  if [[ "${MIFA_TEST_DISPOSABLE:-0}" != "1" ]]; then
    echo "Этот набор меняет систему и запускается только в одноразовом контейнере:" >&2
    echo "  tests/run-docker.sh <suite> <ubuntu-version>" >&2
    exit 2
  fi
  if [[ ! -f /.dockerenv && "${container:-}" != "docker" ]]; then
    echo "MIFA_TEST_DISPOSABLE=1, но признаков контейнера нет: отказ" >&2
    exit 2
  fi
  if [[ "$EUID" -ne 0 ]]; then
    echo "Нужен root внутри контейнера" >&2
    exit 2
  fi
}

# Аргументы источника Xray для установщика: локальный архив или загрузка.
xray_src_args() {
  if [[ -n "${MIFA_TEST_XRAY_ZIP:-}" ]]; then
    printf '%s\n' --xray-zip "$MIFA_TEST_XRAY_ZIP"
  fi
}

free_port() {
  local p
  for p in $(seq 20000 20100); do
    if [[ -z "$(ss -Htln "sport = :$p" 2>/dev/null)" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

start_listener() { # порт; печатает PID
  python3 -c 'import socket, sys, time
port = int(sys.argv[1])
try:
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    s.bind(("::", port))
except OSError:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port))
s.listen(5)
time.sleep(3600)' "$1" >/dev/null 2>&1 &
  echo $!
}

wait_port() { # порт, [секунды]
  local i
  for ((i = 0; i < ${2:-10} * 10; i++)); do
    if [[ -n "$(ss -Htln "sport = :$1" 2>/dev/null)" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Тестовый CA и сертификат: make_cert DIR NAME SAN [ca|self]
make_test_ca() {
  local dir="$1"
  mkdir -p "$dir"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3 \
    -subj "/CN=MIFA Basic Test CA" -keyout "${dir}/ca.key" -out "${dir}/ca.pem" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign >/dev/null 2>&1
}

make_cert() {
  local dir="$1" name="$2" san="$3" mode="${4:-ca}"
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' "$san" >"${dir}/${name}.ext"
  if [[ "$mode" == "self" ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3 \
      -subj "/CN=${san}" -keyout "${dir}/${name}.key" -out "${dir}/${name}.pem" \
      -addext "subjectAltName=DNS:${san}" >/dev/null 2>&1
  else
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=${san}" \
      -keyout "${dir}/${name}.key" -out "${dir}/${name}.csr" >/dev/null 2>&1
    openssl x509 -req -in "${dir}/${name}.csr" -CA "${dir}/ca.pem" -CAkey "${dir}/ca.key" \
      -CAcreateserial -days 3 -extfile "${dir}/${name}.ext" -out "${dir}/${name}.pem" >/dev/null 2>&1
  fi
}

# Запускает тестовый TLS-сервер: start_tls_server ADDR PORT CERTBASE [опции s_server]
start_tls_server() {
  local addr="$1" port="$2" base="$3"
  shift 3
  openssl s_server -accept "${addr}:${port}" -cert "${base}.pem" -key "${base}.key" \
    -www -quiet "$@" </dev/null >/dev/null 2>&1 &
  echo $!
}

# Снимок файловой системы и учётных записей для проверки «ничего не изменено».
# Исключены виртуальные ФС, временные каталоги и MIFA_SNAPSHOT_PRUNE (через пробел).
fs_snapshot() {
  local -a prune=(/proc /sys /dev /run /tmp /var/tmp)
  local p expr=()
  # shellcheck disable=SC2206
  prune+=(${MIFA_SNAPSHOT_PRUNE:-})
  for p in "${prune[@]}"; do
    expr+=(-path "$p" -o)
  done
  unset 'expr[${#expr[@]}-1]'
  find / -xdev \( "${expr[@]}" \) -prune -o -printf '%p|%s|%m|%U|%G|%T@\n' 2>/dev/null | sort
  getent passwd
  getent group
  if [[ -d /run/systemd/system ]]; then
    systemctl list-unit-files --no-legend 2>/dev/null | sort
  fi
}

# Многопоточная TLS-цель для e2e: TLS 1.3, ALPN h2. REALITY-сервер открывает
# соединение к цели на каждое рукопожатие, однопоточный s_server здесь ненадёжен.
start_tls_target() { # ADDR PORT CERTBASE; печатает PID
  python3 -c 'import socket, socketserver, ssl, sys
addr, port, base = sys.argv[1], int(sys.argv[2]), sys.argv[3]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.load_cert_chain(base + ".pem", base + ".key")
ctx.set_alpn_protocols(["h2"])
class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            conn = ctx.wrap_socket(self.request, server_side=True)
            conn.settimeout(10)
            try:
                conn.recv(1)
            except (OSError, ssl.SSLError):
                pass
            conn.close()
        except (OSError, ssl.SSLError):
            pass
class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
Server((addr, port), Handler).serve_forever()' "$1" "$2" "$3" >/dev/null 2>&1 &
  echo $!
}
