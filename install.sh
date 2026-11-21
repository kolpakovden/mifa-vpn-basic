#!/usr/bin/env bash
# MIFA VPN Basic - установщик Xray (VLESS + REALITY) для чистого Ubuntu VPS.
# Самостоятельная публичная редакция: не зависит от MIFA VPN Core и Platform.
#
# Режимы без изменения системы: --preflight, --plan, --dry-run.
# Документация: README.md, docs/RECOVERY.md.
set -Eeuo pipefail
umask 077

readonly MIFA_BASIC_VERSION="1.1.0-dev"

# --- Закреплённый релиз Xray ------------------------------------------------
# Версия и SHA256 официальных архивов https://github.com/XTLS/Xray-core/releases
# меняются только вместе. CI (job xray-pin) сверяет эти значения с файлами
# .dgst релиза и с фактически скачанными архивами. Независимая сверка:
# AUR-пакет xray-bin 26.11.9-1.
readonly XRAY_PINNED_VERSION="v26.11.9"
readonly XRAY_PINNED_SHA256_64="b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82"
readonly XRAY_PINNED_SHA256_ARM64="64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be"
readonly XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/download"

# --- Пути -------------------------------------------------------------------
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONF_DIR="/usr/local/etc/xray"
readonly XRAY_CONF="${XRAY_CONF_DIR}/config.json"
readonly XRAY_UNIT="/etc/systemd/system/xray.service"
readonly XRAY_SERVICE="xray.service"
readonly XRAY_USER="xray"
readonly STATE_DIR="/var/lib/mifa-vpn-basic"
readonly JOURNAL="${STATE_DIR}/journal.inprogress"
readonly MANIFEST="${STATE_DIR}/manifest"
readonly CLIENT_FILE="${STATE_DIR}/client.txt"
readonly BACKUP_ROOT="/var/backups/mifa-vpn-basic"

readonly DEFAULT_PORT="8443"
readonly FINGERPRINT="chrome"
readonly FLOW="xtls-rprx-vision"
readonly LINK_NAME="MIFA-VPN-basic"
readonly MIN_FREE_KB_TMP=$((200 * 1024))
readonly MIN_FREE_KB_INSTALL=$((100 * 1024))

# Адреса, к которым клиенты VPN не должны получать доступ через сервер:
# локальные сервисы VPS, metadata API облака, частные и служебные сети.
readonly BLOCKED_CIDRS='"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10"'

# --- Состояние --------------------------------------------------------------
MODE="install"
PORT=""
SNI=""
TARGET=""
TARGET_HOST=""
TARGET_PORT=""
SERVER_ADDRESS=""
NON_INTERACTIVE=0
ASSUME_YES=0
PRINT_SECRETS=1
XRAY_VERSION="$XRAY_PINNED_VERSION"
XRAY_VERSION_OVERRIDE=0
XRAY_SHA256=""
XRAY_ZIP=""
XRAY_ASSET_ARCH=""
EXPECTED_SHA256=""
UNZIP_TOOL=""

PF_FAIL=0
PF_WARN=0
XRAY_EVIDENCE=()
REALITY_ERROR=""
REDIRECT_TO=""

WORKDIR=""
TXN_ACTIVE=0
BACKUP_DIR=""
BACKUP_PATH=""
USER_CREATED=0

CLIENT_UUID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
SHORT_ID=""
X25519_PRIVATE=""
X25519_PUBLIC=""

# --- Вывод ------------------------------------------------------------------
info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

pf_ok()   { printf '  [OK]   %s\n' "$*"; }
pf_info() { printf '  [INFO] %s\n' "$*"; }
pf_warn() { PF_WARN=$((PF_WARN + 1)); printf '  [WARN] %s\n' "$*"; }
pf_fail() { PF_FAIL=$((PF_FAIL + 1)); printf '  [FAIL] %s\n' "$*"; }

usage() {
  cat <<EOF
MIFA VPN Basic ${MIFA_BASIC_VERSION} - установка Xray (VLESS + REALITY) на чистый Ubuntu VPS

Использование:
  sudo bash install.sh --sni DOMAIN [--target HOST:PORT] [--port N|--443|--8443]
  bash install.sh --preflight [--sni DOMAIN] [--port N]
  bash install.sh --plan --sni DOMAIN [--port N]
  bash install.sh --dry-run --sni DOMAIN [--port N]
  sudo bash install.sh --rollback

Режимы (по умолчанию - установка):
  --preflight          Только проверки готовности системы. Ничего не меняет.
  --plan               Проверки и подробный план действий. Ничего не меняет.
  --dry-run            Проверки, план, загрузка и проверка SHA256 Xray, генерация
                       и проверка конфига во временном каталоге. Системные файлы
                       не меняются, временный каталог удаляется.
  --rollback           Откатить прерванную установку по журналу
                       ${JOURNAL}.

Параметры REALITY:
  --sni DOMAIN         serverName для клиента. Обязателен для установки, по
                       умолчанию не выбирается.
  --target HOST:PORT   Цель REALITY (по умолчанию DOMAIN:443). Проверяется:
                       DNS, не локальный и не частный адрес, TLS 1.3, X25519,
                       HTTP/2, действительный сертификат для DOMAIN.

Прочие параметры:
  --port N             Входящий TCP-порт (по умолчанию ${DEFAULT_PORT})
  --443, --8443        Быстрый выбор порта
  --server-address A   Адрес сервера для ссылки клиента (по умолчанию внешний
                       IPv4 определяется через https://api.ipify.org)
  --non-interactive    Без вопросов (значения из флагов и умолчаний)
  -y, --yes            Не спрашивать подтверждение установки
  --no-print-secrets   Не печатать UUID, ключ и ссылку (только в файл
                       ${CLIENT_FILE})
  --xray-zip FILE      Локальный архив Xray-linux-*.zip вместо загрузки
                       (SHA256 проверяется так же)
  --xray-version VER   Другая версия Xray; требует --xray-sha256
  --xray-sha256 HASH   Ожидаемый SHA256 архива для --xray-version/--xray-zip
  --version            Версия установщика
  -h, --help           Эта справка

Закреплённая версия Xray: ${XRAY_PINNED_VERSION}
EOF
}

usage_error() {
  err "$*"
  echo "Справка: bash install.sh --help" >&2
  exit 2
}

# --- Разбор аргументов ------------------------------------------------------
set_mode() {
  if [[ "$MODE" != "install" && "$MODE" != "$1" ]]; then
    usage_error "Можно указать только один режим (--preflight, --plan, --dry-run, --rollback)"
  fi
  MODE="$1"
}

need_value() {
  if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
    usage_error "Опция $1 требует значение"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)            need_value "$@"; PORT="$2"; shift 2 ;;
      --443)             PORT="443"; shift ;;
      --8443)            PORT="8443"; shift ;;
      --sni)             need_value "$@"; SNI="$2"; shift 2 ;;
      --target)          need_value "$@"; TARGET="$2"; shift 2 ;;
      --server-address)  need_value "$@"; SERVER_ADDRESS="$2"; shift 2 ;;
      --xray-zip)        need_value "$@"; XRAY_ZIP="$2"; shift 2 ;;
      --xray-version)    need_value "$@"; XRAY_VERSION="$2"; XRAY_VERSION_OVERRIDE=1; shift 2 ;;
      --xray-sha256)     need_value "$@"; XRAY_SHA256="$2"; shift 2 ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      -y|--yes)          ASSUME_YES=1; shift ;;
      --no-print-secrets) PRINT_SECRETS=0; shift ;;
      --preflight)       set_mode preflight; shift ;;
      --plan)            set_mode plan; shift ;;
      --dry-run)         set_mode dry-run; shift ;;
      --rollback)        set_mode rollback; shift ;;
      --version)         echo "$MIFA_BASIC_VERSION"; exit 0 ;;
      -h|--help)         usage; exit 0 ;;
      *)                 usage_error "Неизвестный аргумент: $1" ;;
    esac
  done
}

# --- Валидация --------------------------------------------------------------
validate_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

validate_domain() {
  local d="$1" label
  local -a labels
  [[ ${#d} -ge 3 && ${#d} -le 253 ]] || return 1
  [[ "$d" == *.* && "$d" != .* && "$d" != *. && "$d" != *..* ]] || return 1
  IFS=. read -r -a labels <<<"$d"
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  done
  # Последняя метка не может быть числом: иначе это IPv4, а не домен.
  [[ ! "${labels[${#labels[@]}-1]}" =~ ^[0-9]+$ ]]
}

validate_ipv4() {
  local -a parts
  local o
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  parts=("${BASH_REMATCH[@]:1}")
  for o in "${parts[@]}"; do
    [[ "$o" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    (( o <= 255 )) || return 1
  done
}

validate_ipv6() {
  [[ "$1" == *:* && ${#1} -le 45 && "$1" =~ ^[0-9A-Fa-f:.]+$ ]]
}

validate_uuid() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

validate_x25519_key() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{43}$ ]]
}

# Разбирает HOST:PORT в TARGET_HOST/TARGET_PORT. HOST: домен, IPv4 или [IPv6].
parse_target() {
  local t="$1" host port
  if [[ "$t" =~ ^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1],,}"
    port="${BASH_REMATCH[2]}"
    validate_ipv6 "$host" || return 1
  elif [[ "$t" =~ ^([^:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1],,}"
    port="${BASH_REMATCH[2]}"
    validate_ipv4 "$host" || validate_domain "$host" || return 1
  else
    return 1
  fi
  validate_port "$port" || return 1
  TARGET_HOST="$host"
  TARGET_PORT="$port"
}

# 0, если адрес нельзя использовать как цель REALITY: локальные, частные,
# служебные, multicast и прочие адреса, недоступные из интернета.
is_restricted_ip() {
  local ip="${1,,}" a b c d h
  if [[ "$ip" == *:* ]]; then
    if [[ "$ip" == ::ffff:* && "${ip#::ffff:}" == *.* ]]; then
      is_restricted_ip "${ip#::ffff:}"
      return
    fi
    h="${ip%%:*}"
    [[ -n "$h" ]] || return 0              # ::, ::1 и прочие ::/8
    [[ "$h" =~ ^[0-9a-f]{1,4}$ ]] || return 0
    h="$(printf '%04x' "$((16#$h))")"
    case "$h" in
      0000) return 0 ;;                     # ::/16 (unspecified, loopback, совместимые)
      fc*|fd*) return 0 ;;                  # fc00::/7 ULA
      fe*) return 0 ;;                      # fe80::/10 link-local, fec0::/10
      ff*) return 0 ;;                      # multicast
    esac
    return 1
  fi
  validate_ipv4 "$ip" || return 0
  IFS=. read -r a b c d <<<"$ip"
  : "$d"
  if (( a == 0 || a == 10 || a == 127 || a >= 224 )); then return 0; fi
  if (( a == 169 && b == 254 )); then return 0; fi
  if (( a == 172 && b >= 16 && b <= 31 )); then return 0; fi
  if (( a == 192 && b == 168 )); then return 0; fi
  if (( a == 100 && b >= 64 && b <= 127 )); then return 0; fi
  if (( a == 192 && b == 0 && c == 0 )); then return 0; fi
  if (( a == 198 && (b == 18 || b == 19) )); then return 0; fi
  return 1
}

is_tty() { [[ -t 0 ]]; }

prompt_value() { # $1 - текст вопроса; результат в REPLY
  REPLY=""
  read -r -p "$1" REPLY || die "Не удалось прочитать ответ (нет терминала). Используйте --non-interactive и флаги."
}

normalize_inputs() {
  local interactive=0
  if [[ "$NON_INTERACTIVE" == "0" ]] && is_tty; then
    interactive=1
  fi

  if [[ -z "$PORT" ]]; then
    if (( interactive )) && [[ "$MODE" == "install" ]]; then
      prompt_value "Введите порт (по умолчанию ${DEFAULT_PORT}): "
      PORT="${REPLY:-$DEFAULT_PORT}"
    else
      PORT="$DEFAULT_PORT"
    fi
  fi
  if ! validate_port "$PORT"; then
    usage_error "Некорректный порт: $PORT (допустимо 1-65535, без ведущих нулей)"
  fi

  if [[ -z "$SNI" && "$MODE" != "preflight" && "$MODE" != "rollback" ]]; then
    if (( interactive )); then
      echo "REALITY маскирует трафик под TLS-соединение с реальным сайтом."
      echo "Укажите домен, доступный с этого сервера по TLS 1.3 и HTTP/2."
      echo "Домен по умолчанию не выбирается: он будет проверен перед установкой."
      prompt_value "Домен для REALITY (SNI): "
      SNI="$REPLY"
    fi
    if [[ -z "$SNI" ]]; then
      usage_error "Не задан --sni DOMAIN. Basic не выбирает неподтверждённый домен молча."
    fi
  fi

  if [[ -n "$SNI" ]]; then
    SNI="${SNI,,}"
    validate_domain "$SNI" || usage_error "Некорректный SNI: $SNI (нужен домен, например example.com)"
    TARGET="${TARGET:-${SNI}:443}"
  fi
  if [[ -n "$TARGET" ]]; then
    parse_target "$TARGET" || usage_error "Некорректный target: $TARGET (пример: example.com:443)"
    if [[ "$TARGET_HOST" == *:* ]]; then
      TARGET="[${TARGET_HOST}]:${TARGET_PORT}"
    else
      TARGET="${TARGET_HOST}:${TARGET_PORT}"
    fi
  fi

  if [[ -n "$SERVER_ADDRESS" ]]; then
    SERVER_ADDRESS="${SERVER_ADDRESS,,}"
    if ! { validate_ipv4 "$SERVER_ADDRESS" || validate_ipv6 "$SERVER_ADDRESS" || validate_domain "$SERVER_ADDRESS"; }; then
      usage_error "Некорректный --server-address: $SERVER_ADDRESS"
    fi
  fi

  if [[ -n "$XRAY_SHA256" ]]; then
    XRAY_SHA256="${XRAY_SHA256,,}"
    [[ "$XRAY_SHA256" =~ ^[0-9a-f]{64}$ ]] || usage_error "Некорректный --xray-sha256: нужен SHA256 из 64 hex-символов"
  fi
  if (( XRAY_VERSION_OVERRIDE )); then
    [[ "$XRAY_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage_error "Некорректная --xray-version: $XRAY_VERSION (пример: v26.11.9)"
    if [[ "$XRAY_VERSION" != "$XRAY_PINNED_VERSION" && -z "$XRAY_SHA256" ]]; then
      usage_error "--xray-version ${XRAY_VERSION} требует --xray-sha256: установка без проверки целостности не выполняется"
    fi
  fi
  if [[ -n "$XRAY_ZIP" ]]; then
    [[ -f "$XRAY_ZIP" && -r "$XRAY_ZIP" ]] || usage_error "Файл --xray-zip не найден или недоступен: $XRAY_ZIP"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  XRAY_ASSET_ARCH="64"; EXPECTED_SHA256="$XRAY_PINNED_SHA256_64" ;;
    aarch64|arm64) XRAY_ASSET_ARCH="arm64-v8a"; EXPECTED_SHA256="$XRAY_PINNED_SHA256_ARM64" ;;
    *)             XRAY_ASSET_ARCH=""; EXPECTED_SHA256="" ;;
  esac
  if [[ -n "$XRAY_SHA256" ]]; then
    EXPECTED_SHA256="$XRAY_SHA256"
  fi
  [[ -n "$XRAY_ASSET_ARCH" ]]
}

xray_zip_url() {
  printf '%s/%s/Xray-linux-%s.zip' "$XRAY_RELEASE_BASE" "$XRAY_VERSION" "$XRAY_ASSET_ARCH"
}

# --- Сеть и порты -----------------------------------------------------------
port_listeners() {
  ss -Htln "sport = :$1" 2>/dev/null
}

port_in_use() {
  local out
  out="$(port_listeners "$1")" || return 0   # без ss безопаснее считать порт занятым
  [[ -n "$out" ]]
}

port_owner() {
  local out
  out="$(ss -Htlnp "sport = :$1" 2>/dev/null || true)"
  grep -o 'users:(([^)]*))' <<<"$out" | sed -n '1p' || true
}

resolve_host() {
  local h="$1"
  if validate_ipv4 "$h" || validate_ipv6 "$h"; then
    printf '%s\n' "$h"
    return 0
  fi
  getent ahosts "$h" 2>/dev/null | awk '{print $1}' | sort -u
}

own_addresses() {
  if command -v ip >/dev/null 2>&1; then
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
  fi
}

# Пробное TLS-соединение: $1 host, $2 port, $3 SNI, далее опции s_client.
tls_probe() {
  local host="$1" port="$2" sni="$3" connect
  shift 3
  connect="${host}:${port}"
  if [[ "$host" == *:* ]]; then
    connect="[${host}]:${port}"
  fi
  timeout "${MIFA_PROBE_TIMEOUT:-15}" openssl s_client -connect "$connect" -servername "$sni" "$@" </dev/null 2>&1
}

tls13_established() {
  grep -q '^New, TLSv1\.3, Cipher is TLS_' <<<"$1"
}

# Проверяет пригодность цели для REALITY. При отказе - REALITY_ERROR.
reality_tls_check() {
  local host="$1" port="$2" sni="$3" out verr
  REALITY_ERROR=""
  if out="$(tls_probe "$host" "$port" "$sni" -tls1_3 -groups X25519 -alpn h2 \
              -verify_hostname "$sni" -verify_return_error)" \
     && tls13_established "$out" \
     && grep -q 'Verify return code: 0 (ok)' <<<"$out"; then
    if grep -q '^ALPN protocol: h2' <<<"$out"; then
      return 0
    fi
    REALITY_ERROR="цель не поддерживает HTTP/2 (ALPN h2)"
    return 1
  fi

  # Диагностика причины отказа.
  if ! out="$(tls_probe "$host" "$port" "$sni")" \
     || ! grep -Eq '^New, TLSv1(\.[0-3])?, Cipher is ' <<<"$out"; then
    REALITY_ERROR="не удалось установить TLS-соединение с ${host}:${port}"
    return 1
  fi
  if ! out="$(tls_probe "$host" "$port" "$sni" -tls1_3)" || ! tls13_established "$out"; then
    REALITY_ERROR="цель не поддерживает TLS 1.3"
    return 1
  fi
  if ! out="$(tls_probe "$host" "$port" "$sni" -tls1_3 -groups X25519)" || ! tls13_established "$out"; then
    REALITY_ERROR="цель не поддерживает обмен ключами X25519"
    return 1
  fi
  out="$(tls_probe "$host" "$port" "$sni" -tls1_3 -groups X25519 -verify_hostname "$sni" || true)"
  verr="$(grep -m1 'Verify return code:' <<<"$out" || true)"
  REALITY_ERROR="сертификат цели не подтверждается для ${sni} (${verr:-ошибка проверки сертификата})"
  return 1
}

# 0 - редиректа на другой домен нет; 1 - есть (REDIRECT_TO); 2 - не проверить.
reality_redirect_check() {
  local host="$1" port="$2" sni="$3" res code loc lhost chost="$1"
  REDIRECT_TO=""
  if [[ "$host" == *:* ]]; then
    chost="[${host}]"
  fi
  res="$(curl -sS -o /dev/null --proto '=https' --max-time 10 \
          -w '%{http_code} %{redirect_url}' \
          --connect-to "${sni}:443:${chost}:${port}" "https://${sni}/" 2>/dev/null)" || return 2
  code="${res%% *}"
  loc="${res#* }"
  if [[ "$code" == 3* && -n "$loc" ]]; then
    lhost="$(sed -E 's#^[A-Za-z]+://([^/:?]+).*#\1#' <<<"$loc")"
    if [[ "${lhost,,}" != "$sni" ]]; then
      REDIRECT_TO="$loc"
      return 1
    fi
  fi
  return 0
}

# --- Обнаружение существующих установок -------------------------------------
detect_existing_xray() {
  XRAY_EVIDENCE=()
  local p cmd state comm f
  local -a paths=(
    /usr/local/bin/xray /usr/bin/xray /etc/xray
    /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
    /etc/systemd/system/xray.service.d
    /lib/systemd/system/xray.service /lib/systemd/system/xray@.service
    /usr/lib/systemd/system/xray.service /usr/lib/systemd/system/xray@.service
  )
  for p in "${paths[@]}"; do
    if [[ -e "$p" || -L "$p" ]]; then
      XRAY_EVIDENCE+=("$p")
    fi
  done
  cmd="$(command -v xray 2>/dev/null || true)"
  if [[ -n "$cmd" && "$cmd" != "/usr/local/bin/xray" && "$cmd" != "/usr/bin/xray" ]]; then
    XRAY_EVIDENCE+=("команда xray: $cmd")
  fi
  if [[ -e "$XRAY_CONF_DIR" && ! -d "$XRAY_CONF_DIR" ]]; then
    XRAY_EVIDENCE+=("$XRAY_CONF_DIR (не каталог)")
  elif [[ -d "$XRAY_CONF_DIR" && -n "$(ls -A "$XRAY_CONF_DIR" 2>/dev/null)" ]]; then
    XRAY_EVIDENCE+=("$XRAY_CONF_DIR (не пуст)")
  fi
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    if systemctl is-active --quiet "$XRAY_SERVICE" 2>/dev/null; then
      XRAY_EVIDENCE+=("сервис $XRAY_SERVICE активен")
    fi
    state="$(systemctl show -p LoadState --value "$XRAY_SERVICE" 2>/dev/null || true)"
    if [[ "$state" == "loaded" || "$state" == "masked" ]]; then
      XRAY_EVIDENCE+=("unit $XRAY_SERVICE: $state")
    fi
  fi
  for f in /proc/[0-9]*/comm; do
    comm=""
    read -r comm <"$f" 2>/dev/null || continue
    if [[ "$comm" == "xray" ]]; then
      XRAY_EVIDENCE+=("запущен процесс xray (pid $(basename "$(dirname "$f")"))")
      break
    fi
  done
  return 0
}

# --- Preflight --------------------------------------------------------------
free_kb() {
  local p="$1"
  while [[ ! -e "$p" ]]; do
    p="$(dirname "$p")"
  done
  df -Pk "$p" 2>/dev/null | awk 'NR == 2 {print $4}'
}

pf_check_root() {
  if [[ "$EUID" -eq 0 ]]; then
    pf_ok "запуск от root"
  else
    pf_warn "запуск без root: часть проверок ограничена; для установки нужен sudo"
  fi
}

pf_check_os() {
  local id="" ver="" pretty=""
  if [[ -r /etc/os-release ]]; then
    id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
    ver="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')"
    pretty="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')"
  fi
  case "${id}:${ver}" in
    ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) pf_ok "ОС: ${pretty}" ;;
    ubuntu:*) pf_warn "Ubuntu ${ver} не входит в проверяемые версии (22.04, 24.04, 26.04)" ;;
    *) pf_warn "ОС ${pretty:-не определена}: Basic проверяется только на Ubuntu 22.04, 24.04, 26.04" ;;
  esac
}

pf_check_arch() {
  if detect_arch; then
    pf_ok "архитектура $(uname -m): архив Xray-linux-${XRAY_ASSET_ARCH}.zip"
  else
    pf_fail "архитектура $(uname -m) не поддерживается (нужна x86_64 или aarch64)"
  fi
}

pf_check_systemd() {
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    pf_ok "systemd работает как init-система"
  else
    pf_fail "systemd не запущен как init-система (контейнер, OpenVZ, WSL?): сервис установить нельзя"
  fi
}

pf_check_commands() {
  local c
  local -a missing=()
  for c in curl openssl sha256sum base64 systemctl ss getent install mktemp timeout \
           awk sed grep sort cut tr id useradd userdel runuser flock df findmnt uname stat; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if (( ${#missing[@]} )); then
    pf_fail "нет команд: ${missing[*]} (Ubuntu: sudo apt-get install -y curl openssl ca-certificates iproute2 util-linux passwd)"
  else
    pf_ok "необходимые команды доступны"
  fi
  if command -v unzip >/dev/null 2>&1; then
    UNZIP_TOOL="unzip"
  elif command -v python3 >/dev/null 2>&1; then
    UNZIP_TOOL="python3"
  elif command -v apt-get >/dev/null 2>&1; then
    UNZIP_TOOL="apt"
    pf_warn "нет unzip: при установке будет выполнено apt-get install unzip"
  else
    UNZIP_TOOL=""
    pf_fail "нет unzip, python3 и apt-get: архив Xray распаковать нечем"
  fi
}

pf_check_disk() {
  local tmp="${TMPDIR:-/tmp}" kb
  kb="$(free_kb "$tmp")"
  if [[ -z "$kb" ]] || (( kb < MIN_FREE_KB_TMP )); then
    pf_fail "мало места во временном каталоге ${tmp}: ${kb:-?} КБ, нужно не менее ${MIN_FREE_KB_TMP} КБ"
  else
    pf_ok "свободно во временном каталоге ${tmp}: $((kb / 1024)) МБ"
  fi
  if command -v findmnt >/dev/null 2>&1 \
     && findmnt -no OPTIONS --target "$tmp" 2>/dev/null | grep -qw noexec; then
    pf_fail "${tmp} смонтирован с noexec: проверка бинарника невозможна; задайте TMPDIR, например TMPDIR=/root/tmp"
  fi
  kb="$(free_kb /usr/local/bin)"
  if [[ -z "$kb" ]] || (( kb < MIN_FREE_KB_INSTALL )); then
    pf_fail "мало места для /usr/local/bin: ${kb:-?} КБ, нужно не менее ${MIN_FREE_KB_INSTALL} КБ"
  else
    pf_ok "свободно для /usr/local/bin: $((kb / 1024)) МБ"
  fi
}

pf_check_journal() {
  if [[ -e "$JOURNAL" ]]; then
    pf_fail "найден журнал незавершённой установки ${JOURNAL}: выполните sudo bash install.sh --rollback"
  fi
}

pf_check_existing_xray() {
  local e
  detect_existing_xray
  if (( ${#XRAY_EVIDENCE[@]} == 0 )); then
    pf_ok "существующей установки Xray не найдено"
    return 0
  fi
  if [[ -f "$MANIFEST" ]]; then
    pf_fail "Basic уже установлен на этом сервере. Повторная установка не выполняется, рабочий конфиг не изменён."
    pf_info "данные клиента: sudo cat ${CLIENT_FILE}; переустановка: sudo bash uninstall.sh, затем install.sh"
  else
    pf_fail "Обнаружена существующая установка Xray. Basic предназначен только для чистого VPS; действующий конфиг не изменён."
  fi
  for e in "${XRAY_EVIDENCE[@]}"; do
    pf_info "найдено: $e"
  done
}

pf_check_other_proxies() {
  local u state
  [[ -d /run/systemd/system ]] || return 0
  for u in x-ui 3x-ui marzban sing-box v2ray hysteria-server trojan-go shadowsocks-libev; do
    state="$(systemctl show -p LoadState --value "${u}.service" 2>/dev/null || true)"
    if [[ "$state" == "loaded" ]]; then
      pf_warn "найден сервис ${u}.service: Basic рассчитан на чистый VPS, возможен конфликт портов"
    fi
  done
}

pf_check_port() {
  local owner
  if ! command -v ss >/dev/null 2>&1; then
    pf_fail "нет утилиты ss (iproute2): занятость порта ${PORT} проверить нельзя"
    return 0
  fi
  if port_in_use "$PORT"; then
    owner="$(port_owner "$PORT")"
    pf_fail "Порт ${PORT}/tcp занят${owner:+ (${owner})}. Освободи его или выбери другой: --port N"
  else
    pf_ok "порт ${PORT}/tcp свободен"
  fi
  if [[ "$PORT" != "443" ]]; then
    pf_info "Xray предупреждает: REALITY не на 443 заметнее для блокировок; порт 443 - флаг --443"
  fi
}

pf_check_firewall() {
  local st rules
  if command -v ufw >/dev/null 2>&1; then
    if [[ "$EUID" -ne 0 ]]; then
      pf_info "ufw: статус доступен только root"
    else
      st="$(ufw status 2>/dev/null || true)"
      if grep -q '^Status: active' <<<"$st"; then
        if grep -Eq "^${PORT}(/tcp)?[[:space:]]+ALLOW" <<<"$st"; then
          pf_ok "ufw активен и разрешает ${PORT}/tcp"
        else
          pf_warn "ufw активен и не разрешает ${PORT}/tcp: sudo ufw allow ${PORT}/tcp"
        fi
      else
        pf_ok "ufw не активен"
      fi
    fi
  fi
  if [[ "$EUID" -eq 0 ]] && command -v nft >/dev/null 2>&1; then
    rules="$(nft list ruleset 2>/dev/null || true)"
    if grep -Eq 'hook input .*policy drop' <<<"$rules"; then
      pf_warn "nftables: политика input = drop; убедитесь, что ${PORT}/tcp разрешён"
    fi
  fi
  pf_info "firewall провайдера отсюда не проверить: откройте ${PORT}/tcp в панели VPS"
}

pf_check_time() {
  local v
  command -v timedatectl >/dev/null 2>&1 || return 0
  [[ -d /run/systemd/system ]] || return 0
  v="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ "$v" == "yes" ]]; then
    pf_ok "часы синхронизированы (NTP)"
  elif [[ "$v" == "no" ]]; then
    pf_warn "часы не синхронизированы (NTP): проверка сертификатов может ошибаться"
  fi
}

pf_check_download() {
  local url
  if [[ -z "$XRAY_ASSET_ARCH" ]]; then
    return 0
  fi
  if [[ -n "$XRAY_ZIP" ]]; then
    pf_ok "используется локальный архив Xray: ${XRAY_ZIP}"
  else
    url="$(xray_zip_url)"
    if curl -sSfL --proto '=https' --tlsv1.2 --max-time 30 -r 0-0 -o /dev/null "$url" 2>/dev/null; then
      pf_ok "релиз Xray доступен: ${url}"
    else
      pf_fail "нет доступа к ${url}: нужен HTTPS-доступ к github.com"
    fi
  fi
  pf_info "Xray ${XRAY_VERSION}, ожидаемый SHA256 архива: ${EXPECTED_SHA256}"
}

pf_check_reality() {
  local a own
  local -a addrs=() restricted=() self=()
  if [[ -z "$SNI" ]]; then
    pf_warn "SNI не задан: проверка REALITY пропущена (задайте --sni DOMAIN)"
    return 0
  fi
  pf_info "REALITY: SNI=${SNI}, target=${TARGET}"
  mapfile -t addrs < <(resolve_host "$TARGET_HOST" || true)
  if (( ${#addrs[@]} == 0 )); then
    pf_fail "DNS: не удалось разрешить ${TARGET_HOST}"
    return 0
  fi
  own="$(own_addresses || true)"
  for a in "${addrs[@]}"; do
    if is_restricted_ip "$a"; then
      restricted+=("$a")
    fi
    if [[ "$TARGET_PORT" == "$PORT" ]] && grep -qxF "$a" <<<"$own"; then
      self+=("$a")
    fi
  done
  if (( ${#restricted[@]} )); then
    pf_fail "target ${TARGET_HOST} указывает на локальный или частный адрес (${restricted[*]}): это открыло бы внутренний сервис из интернета"
    return 0
  fi
  if (( ${#self[@]} )); then
    pf_fail "target ${TARGET} указывает на сам сервер и порт ${PORT}: получится петля"
    return 0
  fi
  pf_ok "DNS: ${TARGET_HOST} -> ${addrs[*]}"
  if ! command -v openssl >/dev/null 2>&1; then
    return 0
  fi
  if reality_tls_check "$TARGET_HOST" "$TARGET_PORT" "$SNI"; then
    pf_ok "target ${TARGET}: TLS 1.3, X25519, HTTP/2 и сертификат для ${SNI} подтверждены"
  else
    pf_fail "REALITY target не подходит: ${REALITY_ERROR}"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    reality_redirect_check "$TARGET_HOST" "$TARGET_PORT" "$SNI" && a=0 || a=$?
    case "$a" in
      0) pf_ok "https://${SNI}/ не перенаправляет на другой домен" ;;
      1) pf_warn "https://${SNI}/ перенаправляет на ${REDIRECT_TO}: для REALITY лучше домен без редиректа" ;;
      *) pf_info "HTTP-ответ https://${SNI}/ проверить не удалось (не критично)" ;;
    esac
  fi
}

run_preflight() {
  PF_FAIL=0
  PF_WARN=0
  echo "== Preflight: проверка готовности системы (система не изменяется) =="
  pf_check_root
  pf_check_os
  pf_check_arch
  pf_check_systemd
  pf_check_commands
  pf_check_disk
  pf_check_journal
  pf_check_existing_xray
  pf_check_other_proxies
  pf_check_port
  pf_check_firewall
  pf_check_time
  pf_check_download
  pf_check_reality
  echo "Итог preflight: ошибок ${PF_FAIL}, предупреждений ${PF_WARN}"
}

# --- План -------------------------------------------------------------------
PLAN_N=0
plan_step() {
  PLAN_N=$((PLAN_N + 1))
  printf '  %2d. %s\n' "$PLAN_N" "$1"
  shift
  local line
  for line in "$@"; do
    printf '      %s\n' "$line"
  done
}

print_plan() {
  local src
  PLAN_N=0
  echo "== План установки (система пока не изменена) =="
  if [[ "$UNZIP_TOOL" == "apt" ]]; then
    plan_step "Установить пакет unzip: apt-get install unzip (не откатывается)"
  fi
  if [[ -n "$XRAY_ZIP" ]]; then
    src="локальный архив ${XRAY_ZIP}"
  else
    src="$(xray_zip_url)"
  fi
  plan_step "Получить Xray ${XRAY_VERSION}: ${src}" \
            "проверить SHA256 = ${EXPECTED_SHA256:-?}" \
            "сверить .dgst релиза; распаковать только бинарник xray во временный каталог"
  plan_step "Сгенерировать UUID, ключи REALITY (X25519) и shortId" \
            "сверить открытый ключ независимым вычислением через openssl"
  plan_step "Собрать конфиг во временном каталоге и проверить: xray run -test"
  plan_step "Начать журнал изменений ${JOURNAL}" \
            "при любой ошибке выполняется автоматический откат"
  plan_step "Создать системного пользователя ${XRAY_USER} без shell и home (если его нет)"
  plan_step "Установить ${XRAY_BIN} (root:root 0755)"
  plan_step "Установить ${XRAY_CONF} (root:${XRAY_USER} 0640) атомарной заменой" \
            "повторно проверить xray run -test от имени ${XRAY_USER}"
  plan_step "Создать ${XRAY_UNIT} (User=${XRAY_USER}, CAP_NET_BIND_SERVICE, ProtectSystem=strict)" \
            "systemctl daemon-reload, enable и start ${XRAY_SERVICE}"
  plan_step "Проверить: сервис активен, слушает ${PORT}/tcp, REALITY отвечает сертификатом ${SNI:-SNI}"
  plan_step "Сохранить данные клиента в ${CLIENT_FILE} (0600) и манифест ${MANIFEST}" \
            "завершить журнал; откат после этого не выполняется"
  echo "  Параметры: порт ${PORT}/tcp, SNI ${SNI:-не задан}, target ${TARGET:-не задан}"
  if [[ -n "$SERVER_ADDRESS" ]]; then
    echo "  Адрес сервера в ссылке: ${SERVER_ADDRESS}"
  else
    echo "  Адрес сервера в ссылке: внешний IPv4 через https://api.ipify.org (или --server-address)"
  fi
  echo "  Не изменяется: SSH, firewall, другие сервисы и пакеты (кроме unzip при необходимости)."
}

# --- Xray: загрузка, проверка, ключи ------------------------------------------
make_workdir() {
  if [[ -z "$WORKDIR" ]]; then
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/mifa-basic.XXXXXXXX")"
    chmod 0700 "$WORKDIR"
  fi
}

verify_sha256() {
  local file="$1" expected="$2" actual
  actual="$(sha256sum -- "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    rm -f -- "$file"
    die "SHA256 архива Xray не совпадает: ожидалось ${expected}, получено ${actual}. Архив удалён, система не изменена."
  fi
  ok "SHA256 архива Xray подтверждён: ${actual}"
}

fetch_xray_zip() {
  local dest="$1" url dg
  [[ -n "$EXPECTED_SHA256" ]] || die "Неизвестен ожидаемый SHA256 архива Xray"
  if [[ -n "$XRAY_ZIP" ]]; then
    info "Используем локальный архив Xray: ${XRAY_ZIP}"
    cp -- "$XRAY_ZIP" "$dest"
  else
    url="$(xray_zip_url)"
    info "Скачиваем ${url}"
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 3 \
         --connect-timeout 20 --max-time 900 -o "$dest" "$url" \
      || die "Не удалось скачать ${url}"
    if curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --max-time 60 -o "${dest}.dgst" "${url}.dgst" 2>/dev/null; then
      dg="$(sed -nE 's/^SHA(2-)?256 *= *([0-9A-Fa-f]{64}).*$/\2/p' "${dest}.dgst" | sed -n '1p')"
      if [[ -z "$dg" ]]; then
        warn "В .dgst релиза нет SHA256; проверка выполняется по закреплённому значению"
      elif [[ "${dg,,}" != "$EXPECTED_SHA256" ]]; then
        die "SHA256 в .dgst релиза (${dg,,}) не совпадает с ожидаемым (${EXPECTED_SHA256}). Установка остановлена."
      else
        ok ".dgst релиза совпадает с ожидаемым SHA256"
      fi
    else
      warn "Не удалось скачать ${url}.dgst; проверка выполняется по закреплённому SHA256"
    fi
  fi
  verify_sha256 "$dest" "$EXPECTED_SHA256"
}

extract_xray() {
  local zip="$1" dir="$2"
  mkdir -p -- "$dir"
  case "$UNZIP_TOOL" in
    unzip)
      unzip -q -o "$zip" xray -d "$dir" >/dev/null 2>&1 || die "Не удалось распаковать xray из архива ${zip}"
      ;;
    python3)
      python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract("xray", sys.argv[2])' "$zip" "$dir" 2>/dev/null \
        || die "Не удалось распаковать xray из архива ${zip}"
      ;;
    *)
      die "Нет инструмента для распаковки zip (unzip или python3)"
      ;;
  esac
  if [[ ! -f "${dir}/xray" || -L "${dir}/xray" ]]; then
    die "В архиве нет файла xray"
  fi
  chmod 0755 "${dir}/xray"
}

check_xray_binary() {
  local bin="$1" out first want="${XRAY_VERSION#v}"
  out="$("$bin" version 2>&1)" || die "Бинарник Xray не запускается: ${out}"
  first="${out%%$'\n'*}"
  if [[ "$first" != "Xray ${want} "* ]]; then
    die "Версия Xray не совпадает: ожидалась ${want}, получено: ${first}"
  fi
  ok "Бинарник Xray ${want} запускается"
}

# Разбирает вывод `xray x25519` в X25519_PRIVATE / X25519_PUBLIC. Форматы:
#   старый:   "Private key: ..." / "Public key: ..."
#   v25-v26:  "PrivateKey: ..."  / "Password: ..."
#   v26.11+:  "PrivateKey: ..."  / "Password (PublicKey): ..."
parse_x25519() {
  local out="$1"
  X25519_PRIVATE="$(sed -nE 's/^[[:space:]]*Private[[:space:]]?[Kk]ey:[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*$/\1/p' <<<"$out" | sed -n '1p')"
  X25519_PUBLIC="$(sed -nE 's/^[[:space:]]*(Password[[:space:]]*\(PublicKey\)|Password|Public[[:space:]]?[Kk]ey):[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*$/\2/p' <<<"$out" | sed -n '1p')"
  validate_x25519_key "$X25519_PRIVATE" && validate_x25519_key "$X25519_PUBLIC"
}

b64url_decode() {
  local s="${1//-/+}"
  s="${s//_//}"
  while (( ${#s} % 4 )); do
    s="${s}="
  done
  base64 -d <<<"$s"
}

b64url_encode() {
  base64 -w0 | tr '+/' '-_' | tr -d '='
}

# Независимо вычисляет открытый ключ X25519 из закрытого через openssl.
# Ключ передаётся через файл в каталоге 0700, а не аргументом командной строки.
x25519_public_from_private() {
  local priv="$1" der
  make_workdir
  der="${WORKDIR}/x25519.der"
  { printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'; b64url_decode "$priv"; } >"$der"
  openssl pkey -inform DER -in "$der" -pubout -outform DER 2>/dev/null | tail -c 32 | b64url_encode
  rm -f -- "$der"
}

redact_key_output() {
  sed -E 's/:[[:space:]]*[A-Za-z0-9_-]{20,}/: <скрыто>/'
}

generate_credentials() {
  local bin="$1" out derived
  out="$("$bin" x25519 2>&1 | tr -d '\r')" || die "Команда xray x25519 завершилась с ошибкой"
  if ! parse_x25519 "$out"; then
    err "Не удалось разобрать вывод 'xray x25519'. Формат строк:"
    redact_key_output <<<"$out" >&2
    exit 1
  fi
  derived="$(x25519_public_from_private "$X25519_PRIVATE")"
  if [[ "$derived" != "$X25519_PUBLIC" ]]; then
    die "Открытый ключ REALITY не совпадает с вычисленным из закрытого: разбор вывода xray ошибочен"
  fi
  REALITY_PRIVATE_KEY="$X25519_PRIVATE"
  REALITY_PUBLIC_KEY="$X25519_PUBLIC"
  CLIENT_UUID="$("$bin" uuid | tr -d '\r\n')"
  validate_uuid "$CLIENT_UUID" || die "xray uuid вернул некорректный UUID"
  SHORT_ID="$(openssl rand -hex 8)"
  [[ "$SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || die "Не удалось сгенерировать shortId"
  ok "Ключи REALITY, UUID и shortId сгенерированы и проверены"
}

# --- Шаблоны ----------------------------------------------------------------
render_config() {
  cat <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${CLIENT_UUID}",
            "flow": "${FLOW}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${TARGET}",
          "serverNames": ["${SNI}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [${BLOCKED_CIDRS}],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
}

render_unit() {
  cat <<EOF
# Создано MIFA VPN Basic ${MIFA_BASIC_VERSION}. Удаление: uninstall.sh
[Unit]
Description=Xray VLESS + REALITY (MIFA VPN Basic)
Documentation=https://github.com/kolpakovden/mifa-vpn-basic
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=${XRAY_USER}
Group=${XRAY_USER}
ExecStart=${XRAY_BIN} run -config ${XRAY_CONF}
Restart=on-failure
RestartSec=5s
RestartPreventExitStatus=23
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

build_vless_uri() {
  local host="$SERVER_ADDRESS"
  if [[ "$host" == *:* ]]; then
    host="[${host}]"
  fi
  printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
    "$CLIENT_UUID" "$host" "$PORT" "$FLOW" "$SNI" "$FINGERPRINT" "$REALITY_PUBLIC_KEY" "$SHORT_ID" "$LINK_NAME"
}

render_client_file() {
  cat <<EOF
# MIFA VPN Basic - данные для подключения клиента.
# Храните в секрете: по этим данным к серверу может подключиться любой.
# Создано: $(date -u +%Y-%m-%dT%H:%M:%SZ)
server=${SERVER_ADDRESS}
port=${PORT}
uuid=${CLIENT_UUID}
flow=${FLOW}
security=reality
sni=${SNI}
fingerprint=${FINGERPRINT}
public_key=${REALITY_PUBLIC_KEY}
short_id=${SHORT_ID}
vless_uri=$(build_vless_uri)
EOF
}

render_manifest() {
  cat <<EOF
# MIFA VPN Basic: файлы этой установки. Используется uninstall.sh.
mifa_basic_version=${MIFA_BASIC_VERSION}
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
xray_version=${XRAY_VERSION}
xray_sha256=${EXPECTED_SHA256}
port=${PORT}
sni=${SNI}
target=${TARGET}
user=${XRAY_USER}
user_created=${USER_CREATED}
backup_dir=$([[ -d "$BACKUP_DIR" ]] && printf '%s' "$BACKUP_DIR")
files=${XRAY_BIN} ${XRAY_CONF} ${XRAY_UNIT} ${CLIENT_FILE}
EOF
}

test_config() {
  local bin="$1" cfg="$2" out
  shift 2
  if ! out="$("$@" "$bin" run -test -config "$cfg" 2>&1)"; then
    err "xray run -test отклонил конфиг ${cfg}:"
    printf '%s\n' "$out" | sed -n '1,20p' >&2
    return 1
  fi
  ok "xray run -test: конфиг ${cfg} валиден"
}

redact_config() {
  sed -E \
    -e 's/("privateKey": ")[^"]+/\1<скрыто>/' \
    -e 's/("id": ")[^"]+/\1<скрыто>/' \
    -e 's/("shortIds": \[")[^"]+/\1<скрыто>/'
}

# --- Транзакция и откат -----------------------------------------------------
journal_undo() {
  printf '%s\t%s\t%s\n' "$1" "${2:-}" "${3:-}" >>"$JOURNAL"
  sync "$JOURNAL" 2>/dev/null || true
}

test_fault() {
  # Внедрение сбоев только для автотестов: требует двух переменных окружения.
  [[ "${MIFA_BASIC_TEST_MODE:-0}" == "1" ]] || return 0
  case "${MIFA_BASIC_TEST_FAIL_AT:-}" in
    "$1")      err "Тестовый сбой на шаге $1"; exit 97 ;;
    "$1:kill") kill -KILL "$$" ;;
  esac
  return 0
}

txn_begin() {
  local created=0
  if [[ ! -d "$STATE_DIR" ]]; then
    created=1
  fi
  install -d -m 0700 -o root -g root "$STATE_DIR"
  : >"$JOURNAL"
  chmod 0600 "$JOURNAL"
  printf '# MIFA VPN Basic %s: журнал установки, начат %s\n' "$MIFA_BASIC_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$JOURNAL"
  if (( created )); then
    journal_undo rmdir "$STATE_DIR"
  fi
  BACKUP_DIR="${BACKUP_ROOT}/install-$(date -u +%Y%m%dT%H%M%SZ)"
  TXN_ACTIVE=1
}

backup_path() {
  local p="$1" dest
  install -d -m 0700 "$BACKUP_ROOT" "$BACKUP_DIR"
  dest="${BACKUP_DIR}${p}"
  mkdir -p -- "$(dirname "$dest")"
  cp -a -- "$p" "$dest"
  BACKUP_PATH="$dest"
  info "Резервная копия: ${p} -> ${dest}"
}

txn_mkdir() {
  local dir="$1" mode="$2" owner="$3" group="$4" parent
  parent="$(dirname "$dir")"
  if [[ ! -d "$parent" ]]; then
    txn_mkdir "$parent" 0755 root root
  fi
  if [[ -d "$dir" ]]; then
    journal_undo chmeta "$dir" "$(stat -c '%a:%u:%g' "$dir")"
  elif [[ -e "$dir" || -L "$dir" ]]; then
    die "${dir} существует и не является каталогом"
  else
    journal_undo rmdir "$dir"
  fi
  install -d -m "$mode" -o "$owner" -g "$group" "$dir"
}

txn_install_file() {
  local src="$1" dest="$2" mode="$3" owner="$4" group="$5" tmp
  if [[ ! -d "$(dirname "$dest")" ]]; then
    txn_mkdir "$(dirname "$dest")" 0755 root root
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    backup_path "$dest"
    journal_undo restore "$dest" "$BACKUP_PATH"
  else
    journal_undo remove "$dest"
  fi
  tmp="${dest}.mifa-new.$$"
  journal_undo remove "$tmp"
  install -m "$mode" -o "$owner" -g "$group" -- "$src" "$tmp"
  mv -f -- "$tmp" "$dest"
}

txn_create_user() {
  local uid
  if id -u "$XRAY_USER" >/dev/null 2>&1; then
    uid="$(id -u "$XRAY_USER")"
    [[ "$uid" != "0" ]] || die "Пользователь ${XRAY_USER} имеет UID 0: установка остановлена"
    warn "Пользователь ${XRAY_USER} уже существует (uid ${uid}), используется повторно"
    USER_CREATED=0
    return 0
  fi
  journal_undo userdel "$XRAY_USER"
  if getent group "$XRAY_USER" >/dev/null 2>&1; then
    useradd --system --gid "$XRAY_USER" --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin --comment "Xray (MIFA VPN Basic)" "$XRAY_USER"
  else
    useradd --system --user-group --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin --comment "Xray (MIFA VPN Basic)" "$XRAY_USER"
  fi
  USER_CREATED=1
  ok "Создан системный пользователь ${XRAY_USER}"
}

journal_entry_allowed() {
  local action="$1" a1="$2" a2="$3"
  case "$action" in
    stop|disable) [[ "$a1" == "$XRAY_SERVICE" ]] ;;
    userdel)      [[ "$a1" == "$XRAY_USER" ]] ;;
    remove|rmdir|chmeta|restore)
      [[ "$a1" != *..* ]] || return 1
      case "$a1" in
        "$XRAY_BIN"|"$XRAY_BIN".mifa-new.*|"$XRAY_UNIT"|"$XRAY_UNIT".mifa-new.*) ;;
        "$XRAY_CONF_DIR"|"$XRAY_CONF_DIR"/*|"$STATE_DIR"|"$STATE_DIR"/*) ;;
        /usr/local|/usr/local/bin|/usr/local/etc|/etc/systemd/system) ;;
        *) return 1 ;;
      esac
      if [[ "$action" == "restore" ]]; then
        [[ "$a2" == "$BACKUP_ROOT"/* && "$a2" != *..* ]] || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

txn_rollback() {
  local journal="${1:-$JOURNAL}" i action a1 a2 m u g rmstate=0 rc=0
  local -a lines=()
  set +e
  trap - ERR
  if [[ ! -f "$journal" ]]; then
    TXN_ACTIVE=0
    return 0
  fi
  warn "Откат изменений по журналу ${journal}"
  mapfile -t lines <"$journal"
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    [[ -z "${lines[i]}" || "${lines[i]}" == \#* ]] && continue
    IFS=$'\t' read -r action a1 a2 <<<"${lines[i]}"
    if ! journal_entry_allowed "$action" "$a1" "$a2"; then
      warn "Пропущена недопустимая запись журнала: ${lines[i]}"
      rc=1
      continue
    fi
    case "$action" in
      stop)
        systemctl stop "$a1" >/dev/null 2>&1
        ;;
      disable)
        systemctl disable "$a1" >/dev/null 2>&1
        ;;
      remove)
        if [[ -e "$a1" || -L "$a1" ]]; then
          rm -f -- "$a1" || { warn "Не удалось удалить ${a1}"; rc=1; }
        fi
        ;;
      rmdir)
        if [[ "$a1" == "$STATE_DIR" ]]; then
          rmstate=1
        elif [[ -d "$a1" ]]; then
          rmdir -- "$a1" 2>/dev/null || { warn "Каталог ${a1} не пуст и оставлен"; rc=1; }
        fi
        ;;
      chmeta)
        IFS=: read -r m u g <<<"$a2"
        if ! { chmod "$m" "$a1" && chown "${u}:${g}" "$a1"; }; then
          warn "Не удалось восстановить права ${a1}"
          rc=1
        fi
        ;;
      restore)
        if cp -a -- "$a2" "${a1}.mifa-restore" && mv -f -- "${a1}.mifa-restore" "$a1"; then
          info "Восстановлен ${a1} из ${a2}"
        else
          warn "Не удалось восстановить ${a1} из ${a2}"
          rc=1
        fi
        ;;
      userdel)
        if id -u "$a1" >/dev/null 2>&1; then
          userdel "$a1" >/dev/null 2>&1 || { warn "Не удалось удалить пользователя ${a1}"; rc=1; }
        fi
        ;;
    esac
  done
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload >/dev/null 2>&1
    systemctl reset-failed "$XRAY_SERVICE" >/dev/null 2>&1
  fi
  rm -f -- "$journal"
  if (( rmstate )); then
    rmdir -- "$STATE_DIR" 2>/dev/null
  fi
  TXN_ACTIVE=0
  if (( rc == 0 )); then
    ok "Откат завершён: изменения установщика отменены"
  else
    warn "Откат завершён с предупреждениями: проверьте сообщения выше и docs/RECOVERY.md"
  fi
  return "$rc"
}

txn_commit() {
  rm -f -- "$JOURNAL"
  sync 2>/dev/null || true
  TXN_ACTIVE=0
}

# --- Служебное --------------------------------------------------------------
on_exit() {
  local rc=$?
  trap - EXIT ERR
  set +e
  if [[ "$TXN_ACTIVE" == "1" ]]; then
    err "Установка не завершена (код ${rc}). Выполняется автоматический откат."
    txn_rollback
  fi
  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    rm -rf -- "$WORKDIR"
  fi
  exit "$rc"
}

install_traps() {
  trap on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'err "Команда завершилась с ошибкой (строка ${LINENO}): ${BASH_COMMAND}"' ERR
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "Запусти с sudo или от root"
    exit 1
  fi
}

acquire_lock() {
  local dir="/run/lock"
  [[ -d "$dir" ]] || dir="/run"
  exec 9>"${dir}/mifa-vpn-basic.lock"
  flock -n 9 || die "Установщик уже запущен в другой сессии"
}

confirm_install() {
  if (( ASSUME_YES || NON_INTERACTIVE )); then
    return 0
  fi
  if ! is_tty; then
    die "Нет терминала для подтверждения: добавьте --yes или --non-interactive"
  fi
  prompt_value "Продолжить установку? [y/N]: "
  case "$REPLY" in
    y|Y|yes|д|Д|да) return 0 ;;
    *) info "Установка отменена. Система не изменена."; exit 0 ;;
  esac
}

ensure_unzip_tool() {
  [[ "$UNZIP_TOOL" == "apt" ]] || return 0
  info "Устанавливаем пакет unzip (apt-get)..."
  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get -o DPkg::Lock::Timeout=180 install -y -qq --no-install-recommends unzip >/dev/null 2>&1; then
    if ! { apt-get -o DPkg::Lock::Timeout=180 update -qq >/dev/null 2>&1 \
           && apt-get -o DPkg::Lock::Timeout=180 install -y -qq --no-install-recommends unzip >/dev/null 2>&1; }; then
      die "Не удалось установить unzip через apt-get"
    fi
  fi
  UNZIP_TOOL="unzip"
  ok "Пакет unzip установлен"
}

detect_server_address() {
  local ip
  [[ -z "$SERVER_ADDRESS" ]] || return 0
  ip="$(curl -4 -fsS --proto '=https' --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if validate_ipv4 "$ip"; then
    SERVER_ADDRESS="$ip"
    info "Внешний IPv4 сервера: ${ip} (api.ipify.org)"
  else
    SERVER_ADDRESS="YOUR_SERVER_IP"
    warn "Внешний IP не определён: замените YOUR_SERVER_IP в ссылке или используйте --server-address"
  fi
}

show_service_diagnostics() {
  systemctl status "$XRAY_SERVICE" --no-pager -l 2>&1 | sed -n '1,15p' >&2 || true
  journalctl -u "$XRAY_SERVICE" -n 30 --no-pager 2>&1 | sed -E 's/("privateKey": ")[^"]+/\1<скрыто>/' >&2 || true
}

wait_service_healthy() {
  local i owner
  for ((i = 0; i < 30; i++)); do
    if systemctl is-active --quiet "$XRAY_SERVICE" && port_in_use "$PORT"; then
      sleep 1
      if systemctl is-active --quiet "$XRAY_SERVICE"; then
        owner="$(port_owner "$PORT")"
        if [[ -n "$owner" && "$owner" != *'"xray"'* ]]; then
          err "Порт ${PORT} слушает не Xray: ${owner}"
          return 1
        fi
        ok "Сервис ${XRAY_SERVICE} активен и слушает ${PORT}/tcp"
        return 0
      fi
    fi
    sleep 0.5
  done
  err "Xray не запустился или не слушает порт ${PORT}"
  show_service_diagnostics
  return 1
}

# --- Режимы -----------------------------------------------------------------
do_dry_run_sandbox() {
  local cfg
  echo "== Dry-run: проверка во временном каталоге (системные файлы не меняются) =="
  if [[ -z "$XRAY_ASSET_ARCH" ]]; then
    warn "Архитектура не поддерживается: загрузка Xray пропущена"
    return 0
  fi
  make_workdir
  info "Временный каталог: ${WORKDIR} (будет удалён)"
  fetch_xray_zip "${WORKDIR}/xray.zip"
  if [[ "$UNZIP_TOOL" == "apt" || -z "$UNZIP_TOOL" ]]; then
    warn "Нет unzip и python3: распаковка и проверка конфига в dry-run пропущены (установка поставит unzip)"
    return 0
  fi
  extract_xray "${WORKDIR}/xray.zip" "${WORKDIR}/bin"
  check_xray_binary "${WORKDIR}/bin/xray"
  generate_credentials "${WORKDIR}/bin/xray"
  cfg="${WORKDIR}/config.json"
  render_config >"$cfg"
  test_config "${WORKDIR}/bin/xray" "$cfg" || die "Сгенерированный конфиг не прошёл xray run -test"
  echo "-- Конфиг, который будет установлен (секреты скрыты, ключи в dry-run одноразовые):"
  redact_config <"$cfg"
  SERVER_ADDRESS="${SERVER_ADDRESS:-YOUR_SERVER_IP}"
  echo "-- Формат ссылки клиента:"
  build_vless_uri | sed -E 's#^vless://[^@]+@#vless://<uuid>@#; s#pbk=[^&]+#pbk=<public-key>#; s#sid=[^&]+#sid=<short-id>#'
  echo
  ok "Dry-run завершён: системные файлы не изменены, временные файлы будут удалены"
}

do_install() {
  echo "== Установка =="
  ensure_unzip_tool
  make_workdir
  fetch_xray_zip "${WORKDIR}/xray.zip"
  extract_xray "${WORKDIR}/xray.zip" "${WORKDIR}/bin"
  check_xray_binary "${WORKDIR}/bin/xray"
  generate_credentials "${WORKDIR}/bin/xray"
  detect_server_address
  render_config >"${WORKDIR}/config.json"
  test_config "${WORKDIR}/bin/xray" "${WORKDIR}/config.json" \
    || die "Сгенерированный конфиг не прошёл проверку: система не изменена"
  render_unit >"${WORKDIR}/xray.service"
  render_client_file >"${WORKDIR}/client.txt"

  # Повторная проверка непосредственно перед изменениями.
  detect_existing_xray
  if (( ${#XRAY_EVIDENCE[@]} )); then
    die "Во время подготовки появилась установка Xray (${XRAY_EVIDENCE[*]}): система не изменена"
  fi
  if port_in_use "$PORT"; then
    die "Порт ${PORT} занят: система не изменена"
  fi

  txn_begin
  info "Журнал изменений: ${JOURNAL}"
  txn_create_user
  test_fault after_user
  txn_install_file "${WORKDIR}/bin/xray" "$XRAY_BIN" 0755 root root
  test_fault after_binary
  txn_mkdir "$XRAY_CONF_DIR" 0750 root "$XRAY_USER"
  txn_install_file "${WORKDIR}/config.json" "$XRAY_CONF" 0640 root "$XRAY_USER"
  test_fault after_config
  test_config "$XRAY_BIN" "$XRAY_CONF" runuser -u "$XRAY_USER" -- \
    || die "Установленный конфиг не прошёл проверку от имени ${XRAY_USER}"
  txn_install_file "${WORKDIR}/xray.service" "$XRAY_UNIT" 0644 root root
  test_fault after_unit
  systemctl daemon-reload
  journal_undo disable "$XRAY_SERVICE"
  systemctl enable "$XRAY_SERVICE" >/dev/null 2>&1 || die "systemctl enable ${XRAY_SERVICE} завершился с ошибкой"
  test_fault after_enable
  journal_undo stop "$XRAY_SERVICE"
  if ! systemctl start "$XRAY_SERVICE"; then
    show_service_diagnostics
    die "systemctl start ${XRAY_SERVICE} завершился с ошибкой"
  fi
  wait_service_healthy || die "Сервис Xray не прошёл проверку после запуска"
  test_fault after_start
  if reality_tls_check 127.0.0.1 "$PORT" "$SNI"; then
    ok "REALITY: на 127.0.0.1:${PORT} отвечает настоящий сертификат ${SNI}"
  else
    warn "Проверка маскировки REALITY на 127.0.0.1:${PORT} не прошла: ${REALITY_ERROR}. Сервис оставлен, проверьте подключение клиента."
  fi
  txn_install_file "${WORKDIR}/client.txt" "$CLIENT_FILE" 0600 root root
  render_manifest >"${WORKDIR}/manifest"
  txn_install_file "${WORKDIR}/manifest" "$MANIFEST" 0600 root root
  test_fault before_commit
  txn_commit
  print_result
}

print_result() {
  echo
  ok "Установка завершена"
  if (( PRINT_SECRETS )); then
    echo "Данные для клиента (храните в секрете):"
    echo "  Server:      ${SERVER_ADDRESS}"
    echo "  Port:        ${PORT}"
    echo "  UUID:        ${CLIENT_UUID}"
    echo "  Flow:        ${FLOW}"
    echo "  SNI:         ${SNI}"
    echo "  Fingerprint: ${FINGERPRINT}"
    echo "  PublicKey:   ${REALITY_PUBLIC_KEY}"
    echo "  ShortID:     ${SHORT_ID}"
    echo
    echo "VLESS URI:"
    build_vless_uri
    echo
    echo
  else
    info "Вывод секретов отключён (--no-print-secrets)"
  fi
  info "Данные клиента сохранены: ${CLIENT_FILE} (доступ только root)"
  info "Статус: systemctl status xray; логи: journalctl -u xray -f"
  info "Откройте ${PORT}/tcp в firewall провайдера и проверьте подключение с другого устройства и сети"
}

do_rollback_mode() {
  if [[ ! -f "$JOURNAL" ]]; then
    ok "Журнал незавершённой установки не найден: откатывать нечего"
    return 0
  fi
  txn_rollback "$JOURNAL"
}

main() {
  parse_args "$@"
  normalize_inputs
  install_traps
  case "$MODE" in
    rollback)
      require_root
      acquire_lock
      do_rollback_mode
      ;;
    preflight)
      run_preflight
      (( PF_FAIL == 0 )) || exit 1
      ;;
    plan)
      run_preflight
      print_plan
      (( PF_FAIL == 0 )) || { err "Preflight не пройден: установка была бы отклонена"; exit 1; }
      ;;
    dry-run)
      run_preflight
      print_plan
      do_dry_run_sandbox
      (( PF_FAIL == 0 )) || { err "Preflight не пройден: установка была бы отклонена"; exit 1; }
      ;;
    install)
      require_root
      acquire_lock
      run_preflight
      if (( PF_FAIL > 0 )); then
        die "Preflight не пройден (ошибок: ${PF_FAIL}): система не изменена. Исправьте ошибки выше."
      fi
      print_plan
      confirm_install
      do_install
      ;;
  esac
}

if [[ "${MIFA_BASIC_LIB:-0}" != "1" ]]; then
  main "$@"
fi
