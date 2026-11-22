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
# Откат не выполнен полностью: журнал сохранён, нужна повторная попытка.
readonly RC_ROLLBACK_INCOMPLETE=3
readonly JOURNAL_V2_HEADER='# MIFA VPN Basic journal v2'
readonly JOURNAL_V3_HEADER='# MIFA VPN Basic journal v3'

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
  for c in curl openssl sha256sum base64 systemctl ss getent install mktemp timeout cmp readlink \
           awk sed grep sort cut tr id groupadd useradd userdel runuser flock df findmnt uname stat python3; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if (( ${#missing[@]} )); then
    pf_fail "нет команд: ${missing[*]} (Ubuntu: sudo apt-get install -y curl openssl ca-certificates iproute2 util-linux passwd python3)"
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
# v3 ownership evidence. Standard Python only, executed in isolated mode; no
# installed helper binary. Files/dirs carry a random generation xattr AND a
# dev/inode witness plus expected metadata/content. Copying a token alone or
# reusing an inode/UID is insufficient. This does not defend against malicious
# root copying/reconstructing all evidence or concurrent root account changes.
txn_v3_python() {
  python3 -I - "$@" <<'V3PY'
import errno, hashlib, json, os, posixpath, re, secrets, stat, sys

HEADER = "# MIFA VPN Basic journal v3"
KINDS = {"remove", "rmdir", "chmeta", "userdel"}
HEX = re.compile(r"[0-9a-f]{32}\Z")
KEY = "user.mifa.rollback."

class Refuse(Exception):
    pass

def require(ok, message):
    if not ok:
        raise Refuse(message)

def emit(value):
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))

def fault(point):
    if os.environ.get("MIFA_BASIC_TEST_MODE") == "1" and os.environ.get("MIFA_BASIC_TEST_FAIL_AT") == point + ":kill":
        print("MIFA_V3_KILL\t" + point, file=sys.stderr, flush=True)
        os.kill(os.getppid(), 9); os.kill(os.getpid(), 9)

def decode(value):
    def unique(pairs):
        result = {}
        for k, v in pairs:
            require(k not in result, "duplicate JSON key")
            result[k] = v
        return result
    try:
        return json.loads(value, object_pairs_hook=unique)
    except (ValueError, TypeError) as error:
        raise Refuse("invalid JSON: " + str(error))

def parents(path):
    require(path.startswith("/") and posixpath.normpath(path) == path and "//" not in path,
            "non-canonical path")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.split("/")[1:-1]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
            s = os.fstat(fd)
            require(s.st_uid == 0 and not s.st_mode & 0o022, "untrusted parent directory")
        return fd, os.path.basename(path)
    except BaseException:
        os.close(fd)
        raise

def opened(path):
    parent, leaf = parents(path)
    try:
        fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        return parent, leaf, fd
    except BaseException:
        os.close(parent)
        raise

def attrs(fd, omit=None):
    return {k: os.getxattr(fd, k).hex() for k in sorted(os.listxattr(fd)) if k != omit}

def snapshot(fd, token, directory):
    s = os.fstat(fd)
    require(stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode), "wrong object type")
    result = {"dev": s.st_dev, "ino": s.st_ino, "mode": stat.S_IMODE(s.st_mode),
              "uid": s.st_uid, "gid": s.st_gid, "attrs": attrs(fd, KEY + token)}
    if not directory:
        os.lseek(fd, 0, 0)
        digest = hashlib.sha256()
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            digest.update(block)
        result.update(size=s.st_size, mtime_ns=s.st_mtime_ns, sha256=digest.hexdigest())
    return result

def account(spec, witness=None):
    import pwd, grp
    name = spec["path"]
    def row(file, key):
        s = os.lstat(file)
        require(stat.S_ISREG(s.st_mode) and s.st_uid == 0 and not s.st_mode & 0o022,
                "untrusted account database")
        with open(file, encoding="utf-8") as stream:
            rows = [l.rstrip("\n") for l in stream if l.split(":", 1)[0] == key]
        require(len(rows) <= 1, "duplicate local account/group")
        return rows[0] if rows else None
    user = row("/etc/passwd", name)
    if user is None:
        try: pwd.getpwnam(name)
        except KeyError: pass
        else: raise Refuse("NSS account exists without local ownership evidence")
        require(row("/etc/shadow", name) is None, "orphan shadow entry after account removal")
        require(not spec["group_created"] or row("/etc/group", name) is None,
                "account absent but its group still exists")
        if spec["group_created"]:
            require(row("/etc/gshadow", name) is None, "orphan gshadow entry after group removal")
            try: grp.getgrnam(name)
            except KeyError: pass
            else: raise Refuse("NSS group exists after account removal")
        for file in ("/etc/subuid", "/etc/subgid"):
            if os.path.lexists(file):
                require(row(file, name) is None, "orphan subordinate ID allocation")
                if witness is not None:
                    require(row(file, witness["passwd"].split(":")[2]) is None,
                            "numeric subordinate ID allocation after account removal")
        return None
    fields = user.split(":")
    require(len(fields) == 7 and int(fields[2]) != 0, "invalid/root account")
    require(fields[4] == "Xray (MIFA VPN Basic tx=" + spec["token"] + ")", "account generation changed")
    require(list(pwd.getpwnam(name)) == [fields[0], fields[1], int(fields[2]), int(fields[3]), *fields[4:]],
            "NSS/local account disagreement")
    with open("/etc/passwd", encoding="utf-8") as stream:
        require(sum(l.split(":")[2] == fields[2] for l in stream if l.count(":") >= 2) == 1,
                "UID is shared")
    shadow = row("/etc/shadow", name)
    require(shadow is not None, "missing shadow entry")
    primary = grp.getgrgid(int(fields[3])).gr_name
    local_group = row("/etc/group", name)
    require(primary == name and local_group is not None and local_group.split(":")[2] == fields[3],
            "private primary group changed")
    private_shadow = row("/etc/gshadow", name)
    require(private_shadow is not None and private_shadow.split(":")[1] == "!mifa-tx-" + spec["token"],
            "private group generation changed")
    groups = []
    with open("/etc/group", encoding="utf-8") as stream:
        for line in stream:
            parts = line.rstrip("\n").split(":")
            if len(parts) == 4 and (name in parts[3].split(",") or parts[0] == primary):
                groups.append([line.rstrip("\n"), row("/etc/gshadow", parts[0])])
    subids = []
    for file in ("/etc/subuid", "/etc/subgid"):
        if os.path.lexists(file):
            by_name, by_uid = row(file, name), row(file, fields[2])
            require(by_name is None and by_uid is None, "subordinate ID allocation is not owned by this system-user transaction")
            subids.append([file, by_name, by_uid])
    # No password hashes/secrets are copied into the journal.
    return {"passwd": user, "shadow_sha256": hashlib.sha256(shadow.encode()).hexdigest(),
            "groups_sha256": hashlib.sha256(json.dumps(sorted(groups)).encode()).hexdigest(),
            "subids_sha256": hashlib.sha256(json.dumps(subids).encode()).hexdigest()}

def evidence_shape(value, kind):
    require(isinstance(value, dict), "evidence must be an object")
    if kind == "userdel":
        require(set(value) == {"passwd", "shadow_sha256", "groups_sha256", "subids_sha256"}, "bad account evidence")
        require(all(isinstance(v, str) for v in value.values()) and value["passwd"].count(":") == 6,
                "bad passwd evidence")
        require(all(re.fullmatch(r"[0-9a-f]{64}", value[k]) for k in ("shadow_sha256", "groups_sha256", "subids_sha256")), "bad account digest")
        return
    expected = {"dev", "ino", "mode", "uid", "gid", "attrs"}
    if kind == "remove": expected |= {"size", "mtime_ns", "sha256"}
    require(set(value) == expected, "bad filesystem evidence fields")
    for k in expected - {"attrs", "sha256"}:
        require(type(value[k]) is int and value[k] >= 0, "bad evidence integer")
    require(value["mode"] <= 0o7777 and isinstance(value["attrs"], dict), "bad evidence metadata")
    require(all(isinstance(k, str) and isinstance(v, str) and re.fullmatch(r"(?:[0-9a-f]{2})*", v)
                for k, v in value["attrs"].items()), "bad xattr evidence")
    if kind == "remove":
        require(isinstance(value["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", value["sha256"]), "bad content digest")

def validate(path):
    with open(path, "rb") as stream:
        raw = stream.read()
    require(b"\0" not in raw and raw.endswith(b"\n"), "truncated/binary journal")
    lines = raw.decode("utf-8").splitlines()
    require(lines[0] == HEADER, "not journal v3")
    require(len(lines) >= 2 and lines[1] in ("state\t/var/lib/mifa-vpn-basic\tcreated",
                                            "state\t/var/lib/mifa-vpn-basic\texisting"), "missing state declaration")
    operations, paths, restores, normalized = {}, {}, set(), [lines[1]]
    recovery = False
    for line in lines[2:]:
        if not line or line.startswith("#"):
            require(not line.startswith("# MIFA VPN Basic journal"), "duplicate version")
            continue
        fields = line.split("\t")
        require(len(fields) == 3 and "\r" not in line, "bad field count")
        action, key, arg = fields
        if action == "prepare":
            require(not recovery and HEX.fullmatch(key) and key not in operations, "duplicate/late preparation")
            spec = decode(arg)
            require(isinstance(spec, dict), "preparation must be an object")
            require(set(spec) == {"kind", "path", "token", "before", "target", "group_created"}, "bad preparation schema")
            kind, target, token = spec["kind"], spec["path"], spec["token"]
            require(isinstance(kind, str) and kind in KINDS and isinstance(target, str) and
                    isinstance(token, str) and HEX.fullmatch(token), "bad operation")
            require(not any(c in target for c in "\0\t\r\n") and target not in paths and target not in restores, "duplicate/invalid target")
            require(target == "xray" if kind == "userdel" else
                    target.startswith("/") and posixpath.normpath(target) == target and "//" not in target,
                    "invalid operation path")
            require(kind == "chmeta" and isinstance(spec["before"], dict) and isinstance(spec["target"], dict)
                    or kind != "chmeta" and spec["before"] is None and spec["target"] is None, "bad metadata intent")
            require(isinstance(spec["group_created"], bool), "bad group intent")
            require(spec["group_created"] == (kind == "userdel"), "v3 requires a private transaction-created group")
            if kind == "chmeta":
                evidence_shape(spec["before"], kind)
                target_meta = spec["target"]
                require(set(target_meta) == {"mode", "uid", "gid"} and
                        all(type(v) is int and v >= 0 for v in target_meta.values()) and
                        target_meta["mode"] <= 0o7777, "bad desired metadata")
            operations[key] = {"spec": spec, "phase": "prepared", "witness": None}
            paths[target] = key
            normalized.append("owned-" + kind + "\t" + target + "\t" + key)
        elif action == "ready":
            require(not recovery and key in operations and operations[key]["phase"] == "prepared", "bad readiness")
            witness = decode(arg)
            evidence_shape(witness, operations[key]["spec"]["kind"])
            if operations[key]["spec"]["kind"] == "chmeta":
                spec = operations[key]["spec"]
                require(all(witness[k] == spec["before"][k] for k in ("dev", "ino")) and
                        all(witness[k] == v for k, v in spec["target"].items()), "inconsistent metadata evidence")
            if operations[key]["spec"]["kind"] == "userdel":
                parts = witness["passwd"].split(":")
                require(parts[0] == "xray" and parts[2].isdigit() and int(parts[2]) != 0 and
                        parts[4] == "Xray (MIFA VPN Basic tx=" + operations[key]["spec"]["token"] + ")", "bad account generation")
            operations[key].update(phase="ready", witness=witness)
        elif action in ("undoing", "undone", "cancelled"):
            recovery = True
            require(key in operations and arg == "", "unknown undo ID")
            op = operations[key]
            expected = {"undoing": "ready", "undone": "undoing", "cancelled": "prepared"}[action]
            require(op["phase"] == expected, "invalid undo transition")
            op["phase"] = action
        else:
            require(action in ("stop", "disable", "restore", "restoring", "restored"), "legacy/unknown v3 action")
            if action in ("restoring", "restored"):
                recovery = True
            else:
                require(not recovery, "late installation record")
            require(key not in paths, "conflicting restore/owned path")
            if action == "restore": restores.add(key)
            normalized.append(line)
    return operations, normalized

def main():
    cmd, *a = sys.argv[1:]
    if cmd == "id":
        print(secrets.token_hex(16)); return
    if cmd == "validate":
        _, rows = validate(a[0]); print("\n".join(rows)); return
    if cmd == "spec":
        import pwd, grp
        opid, kind, path, mode, owner, group, token = a
        require(HEX.fullmatch(opid) and HEX.fullmatch(token), "bad generation")
        spec = dict(kind=kind, path=path, token=token, before=None, target=None, group_created=False)
        if kind == "userdel":
            require(path == "xray", "invalid user")
            try: pwd.getpwnam(path)
            except KeyError: pass
            else: raise Refuse("account already exists")
            try: grp.getgrnam(path)
            except KeyError: pass
            else: raise Refuse("pre-existing group is not owned by this transaction")
            spec["group_created"] = True
        elif kind == "chmeta":
            p, _, fd = opened(path)
            try:
                spec["before"] = snapshot(fd, token, True)
                spec["target"] = dict(mode=int(mode, 8), uid=pwd.getpwnam(owner).pw_uid,
                                      gid=grp.getgrnam(group).gr_gid)
            finally: os.close(fd); os.close(p)
        emit(spec); return
    ops, _ = validate(a[0]); opid = a[1]
    require(opid in ops, "unknown operation")
    op = ops[opid]; spec = op["spec"]; kind = spec["kind"]; path = spec["path"]
    if cmd == "status":
        print(op["phase"] + "\t" + kind + "\t" + path); return
    if kind == "userdel":
        current = account(spec, op["witness"])
        if cmd == "witness":
            require(current is not None, "account missing before ready"); emit(current); return
        if cmd in ("absent", "outcome"):
            require(current is None, "account/group exists after deletion"); return
        if cmd == "check":
            require(current is not None and current == op["witness"], "account changed"); return
        raise Refuse("unsupported account operation")
    try:
        p, leaf = parents(path)
    except FileNotFoundError:
        if cmd in ("absent", "outcome") and kind != "chmeta": return
        raise Refuse("parent absent")
    fd = None
    try:
        if cmd in ("create-dir", "create-file"):
            import pwd, grp
            require(op["phase"] == "prepared", "creation without preparation")
            mode, uid, gid = int(a[3], 8), pwd.getpwnam(a[4]).pw_uid, grp.getgrnam(a[5]).gr_gid
            if cmd == "create-dir":
                os.mkdir(leaf, 0o700, dir_fd=p)
                fd = os.open(leaf, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=p)
            else:
                fd = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=p)
                with open(a[2], "rb") as source:
                    while True:
                        block = source.read(1024 * 1024)
                        if not block: break
                        view = memoryview(block)
                        while view: view = view[os.write(fd, view):]
            fault("v3_created_without_generation")
            os.setxattr(fd, KEY + spec["token"], spec["token"].encode(), os.XATTR_CREATE)
            os.fchown(fd, uid, gid); os.fchmod(fd, mode)
            os.fsync(fd); os.fsync(p); return
        try:
            candidate = os.stat(leaf, dir_fd=p, follow_symlinks=False)
            require(stat.S_ISREG(candidate.st_mode) if kind == "remove" else stat.S_ISDIR(candidate.st_mode),
                    "wrong target type")
            fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=p)
        except FileNotFoundError:
            if cmd in ("absent", "outcome") and kind != "chmeta": return
            raise Refuse("target missing")
        if cmd == "absent": sys.exit(1)
        token = spec["token"]; directory = kind != "remove"
        if cmd == "tag":
            require(op["phase"] == "prepared", "not preparing")
            if kind == "chmeta":
                require(snapshot(fd, token, True) == spec["before"], "directory changed before metadata apply")
            os.setxattr(fd, KEY + token, token.encode(), os.XATTR_CREATE)
            if kind == "chmeta":
                target = spec["target"]
                os.fchown(fd, target["uid"], target["gid"])
                os.fchmod(fd, target["mode"])
            os.fsync(fd); os.fsync(p); return
        current = snapshot(fd, token, directory)
        require(os.getxattr(fd, KEY + token) == token.encode(), "generation marker absent/changed")
        if cmd == "witness":
            if kind == "chmeta":
                require((current["dev"], current["ino"]) == (spec["before"]["dev"], spec["before"]["ino"]), "object replaced")
                require(all(current[k] == v for k, v in spec["target"].items()), "metadata application incomplete")
            emit(current); return
        if cmd == "outcome":
            require(kind == "chmeta" and current == spec["before"], "undo result changed")
            return
        require(cmd in ("check", "mutate") and current == op["witness"], "object changed since installation")
        if cmd == "check": return
        require(op["phase"] == "undoing", "missing durable undo intent")
        # p and fd are pinned and symlinks are not followed. Compare directory
        # entry again before unlink/rmdir. Concurrent malicious root is excluded.
        s = os.stat(leaf, dir_fd=p, follow_symlinks=False)
        require((s.st_dev, s.st_ino) == (current["dev"], current["ino"]), "entry replaced")
        if kind == "remove": os.unlink(leaf, dir_fd=p)
        elif kind == "rmdir": os.rmdir(leaf, dir_fd=p)
        else:
            old = spec["before"]
            os.fchown(fd, old["uid"], old["gid"])
            fault("v3_chmeta_partial")
            os.fchmod(fd, old["mode"])
        os.fsync(fd); os.fsync(p)
    finally:
        if fd is not None: os.close(fd)
        os.close(p)

try:
    main()
except (Refuse, KeyError) as error:
    print("v3 safety refusal: " + str(error), file=sys.stderr); sys.exit(1)
except OSError as error:
    if error.errno in (errno.ENOENT, errno.ELOOP, errno.ENOTDIR, errno.ENODATA,
                       errno.ENOTEMPTY, errno.EEXIST, errno.EACCES, errno.EPERM):
        print("v3 safety refusal: " + str(error), file=sys.stderr); sys.exit(1)
    print("MIFA_V3_INFRA_ERROR\t2", file=sys.stderr)
    print("v3 evidence I/O error: " + str(error), file=sys.stderr); sys.exit(2)
except Exception as error:
    print("MIFA_V3_INFRA_ERROR\t2", file=sys.stderr)
    print("v3 evidence error: " + str(error), file=sys.stderr); sys.exit(2)
V3PY
}

txn_v3_prepare() {
  local kind="$1" path="$2" mode="${3:-}" owner="${4:-root}" group="${5:-root}" generation="${6:-}"
  V3_ID="$(txn_v3_python id)" || return 1
  [[ -n "$generation" ]] || generation="$V3_ID"
  local spec
  spec="$(txn_v3_python spec "$V3_ID" "$kind" "$path" "$mode" "$owner" "$group" "$generation")" || return 1
  journal_append "$JOURNAL" prepare "$V3_ID" "$spec" || return 1
  test_fault v3_after_prepare
}

txn_v3_ready() {
  local witness
  test_fault v3_before_ready
  witness="$(txn_v3_python witness "$JOURNAL" "$1")" || return 1
  journal_append "$JOURNAL" ready "$1" "$witness" || return 1
}

txn_v3_undo() {
  local journal="$1" id="$2" phase kind path absent_rc=0
  IFS=$'\t' read -r phase kind path <<<"$(txn_v3_python status "$journal" "$id")"
  [[ -n "$phase" ]] || return 1
  case "$phase" in
    prepared|cancelled)
      txn_v3_python absent "$journal" "$id" || return 1
      if [[ "$phase" == prepared ]]; then journal_append "$journal" cancelled "$id" '' || return 1; fi
      return 0 ;;
    undoing|undone)
      txn_v3_python outcome "$journal" "$id" || return 1
      if [[ "$phase" == undoing ]]; then journal_append "$journal" undone "$id" '' || return 1; fi
      return 0 ;;
    ready) ;;
    *) return 1 ;;
  esac
  # Absence is safe to acknowledge without issuing another delete.
  if [[ "$kind" != chmeta ]]; then
    txn_v3_python absent "$journal" "$id" || absent_rc=$?
    case "$absent_rc" in
      0)
        journal_append "$journal" undoing "$id" '' && journal_append "$journal" undone "$id" ''
        return $? ;;
      1) ;; # Present: an independent full witness check is required below.
      *) return 1 ;; # Do not discard an infrastructure error as mere presence.
    esac
  fi
  txn_v3_python check "$journal" "$id" || return 1
  journal_append "$journal" undoing "$id" '' || return 1
  test_fault "v3_${kind}_before"
  if [[ "$kind" == userdel ]]; then
    txn_v3_python check "$journal" "$id" || return 1
    userdel "$path" || return 1
    sync /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc 2>/dev/null || return 1
  else
    txn_v3_python mutate "$journal" "$id" || return 1
  fi
  test_fault "v3_${kind}_after"
  txn_v3_python outcome "$journal" "$id" || return 1
  test_fault "v3_${kind}_before_done"
  journal_append "$journal" undone "$id" ''
}

journal_undo() {
  journal_append "$JOURNAL" "$1" "${2:-}" "${3:-}"
}

journal_append() {
  local journal="$1" action="$2" dest="$3" arg="$4"
  [[ -f "$journal" && ! -L "$journal" ]] || return 1
  printf '%s\t%s\t%s\n' "$action" "$dest" "$arg" >>"$journal" || return 1
  # A failed flush is a failed write for the protocol. Never authorize a
  # destination replacement merely because the line is visible in page cache.
  sync "$journal" 2>/dev/null || return 1
}

test_fault() {
  # Внедрение сбоев только для автотестов: требует двух переменных окружения.
  [[ "${MIFA_BASIC_TEST_MODE:-0}" == "1" ]] || return 0
  case "${MIFA_BASIC_TEST_FAIL_AT:-}" in
    "$1")      err "Тестовый сбой на шаге $1"; exit 97 ;;
    # Restore runs in a subshell with a pinned cwd. Kill both it and the CLI,
    # otherwise the child could continue mutating files after its parent dies.
    "$1:kill") err "Тестовый SIGKILL на шаге $1"; kill -KILL "$$" "$BASHPID" ;;
  esac
  return 0
}

txn_begin() {
  local created=0
  command -v python3 >/dev/null 2>&1 || { err 'Journal v3 требует python3'; return 1; }
  [[ ! -L "$STATE_DIR" && ( ! -e "$STATE_DIR" || -d "$STATE_DIR" ) ]] || return 1
  [[ ! -e "$JOURNAL" && ! -L "$JOURNAL" ]] || return 1
  if [[ ! -d "$STATE_DIR" ]]; then
    created=1
  fi
  install -d -m 0700 -o root -g root "$STATE_DIR"
  : >"$JOURNAL"
  chmod 0600 "$JOURNAL"
  printf '%s\n' "$JOURNAL_V3_HEADER" >>"$JOURNAL" || return 1
  journal_append "$JOURNAL" state "$STATE_DIR" "$([[ "$created" == 1 ]] && echo created || echo existing)" || return 1
  sync "$JOURNAL" "$STATE_DIR" 2>/dev/null || return 1
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
  local dir="$1" mode="$2" owner="$3" group="$4" parent id
  parent="$(dirname "$dir")"
  if [[ ! -d "$parent" ]]; then
    txn_mkdir "$parent" 0755 root root || return 1
  fi
  if [[ -d "$dir" ]]; then
    txn_v3_prepare chmeta "$dir" "$mode" "$owner" "$group" || return 1
    id="$V3_ID"
    txn_v3_python tag "$JOURNAL" "$id" || return 1
  elif [[ -e "$dir" || -L "$dir" ]]; then
    die "${dir} существует и не является каталогом"
  else
    txn_v3_prepare rmdir "$dir" || return 1
    id="$V3_ID"
    txn_v3_python create-dir "$JOURNAL" "$id" '' "$mode" "$owner" "$group" || return 1
  fi
  txn_v3_ready "$id"
}

txn_install_file() {
  local src="$1" dest="$2" mode="$3" owner="$4" group="$5" tmp dest_id='' tmp_id generation
  if [[ ! -d "$(dirname "$dest")" ]]; then
    txn_mkdir "$(dirname "$dest")" 0755 root root || return 1
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    backup_path "$dest"
    journal_undo restore "$dest" "$BACKUP_PATH" || return 1
  else
    txn_v3_prepare remove "$dest" || return 1
    dest_id="$V3_ID"
  fi
  generation="${dest_id:-$(txn_v3_python id)}" || return 1
  tmp="${dest}.mifa-new.$generation"
  txn_v3_prepare remove "$tmp" '' root root "$generation" || return 1
  tmp_id="$V3_ID"
  txn_v3_python create-file "$JOURNAL" "$tmp_id" "$src" "$mode" "$owner" "$group" || return 1
  txn_v3_ready "$tmp_id" || return 1
  mv -fT -- "$tmp" "$dest" || return 1
  sync "$dest" "$(dirname "$dest")" 2>/dev/null || return 1
  if [[ -n "$dest_id" ]]; then txn_v3_ready "$dest_id" || return 1; fi
}

txn_create_user() {
  local uid id
  if id -u "$XRAY_USER" >/dev/null 2>&1; then
    uid="$(id -u "$XRAY_USER")"
    [[ "$uid" != "0" ]] || die "Пользователь ${XRAY_USER} имеет UID 0: установка остановлена"
    warn "Пользователь ${XRAY_USER} уже существует (uid ${uid}), используется повторно"
    USER_CREATED=0
    return 0
  fi
  txn_v3_prepare userdel "$XRAY_USER" || return 1
  id="$V3_ID"
  # userdel can delete the private group too. A locked, non-password generation
  # is assigned at group creation, never by adopting a pre-existing group.
  groupadd --system --password "!mifa-tx-$id" "$XRAY_USER" || return 1
  sync /etc/group /etc/gshadow /etc 2>/dev/null || return 1
  test_fault v3_userdel_group_created
  useradd --system --gid "$XRAY_USER" --no-user-group --no-create-home --home-dir /nonexistent \
          --shell /usr/sbin/nologin --comment "Xray (MIFA VPN Basic tx=$id)" "$XRAY_USER" || return 1
  sync /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc 2>/dev/null || return 1
  txn_v3_ready "$id" || return 1
  USER_CREATED=1
  ok "Создан системный пользователь ${XRAY_USER}"
}

journal_entry_allowed() {
  local action="$1" a1="$2" a2="$3"
  case "$action" in
    stop|disable) [[ "$a1" == "$XRAY_SERVICE" ]] ;;
    userdel)      [[ "$a1" == "$XRAY_USER" ]] ;;
    remove|rmdir|chmeta|restore|restoring|restored)
      [[ "$a1" != *..* ]] || return 1
      case "$a1" in
        "$XRAY_BIN"|"$XRAY_BIN".mifa-new.*|"$XRAY_UNIT"|"$XRAY_UNIT".mifa-new.*) ;;
        "$XRAY_CONF_DIR"|"$XRAY_CONF_DIR"/*|"$STATE_DIR"|"$STATE_DIR"/*) ;;
        /usr/local|/usr/local/bin|/usr/local/etc|/etc/systemd/system) ;;
        *) return 1 ;;
      esac
      if [[ "$action" == restore || "$action" == restoring || "$action" == restored ]]; then
        [[ "$a2" == "$BACKUP_ROOT"/* && "$a2" != *..* ]] || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

# systemd нужен откату только там, где он есть. Для записей stop/disable его
# отсутствие считается ошибкой: файлы нельзя удалять из-под работающего сервиса.
txn_systemd_available() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

# 0, если запись уже совпадает с резервной копией. Обычные файлы сравниваются
# по содержимому и метаданным; символические ссылки - по типу, цели (readlink,
# без разыменования) и метаданным самой ссылки. Ничего не разыменовывается.
txn_file_matches() {
  local ref="$1" cur="$2" rstat cstat rlink clink
  [[ -e "$ref" || -L "$ref" ]] || return 1
  [[ -e "$cur" || -L "$cur" ]] || return 1
  if [[ -L "$ref" || -L "$cur" ]]; then
    [[ -L "$ref" && -L "$cur" ]] || return 1
    rstat="$(stat -c '%a:%u:%g' -- "$ref" 2>/dev/null)" || return 1
    cstat="$(stat -c '%a:%u:%g' -- "$cur" 2>/dev/null)" || return 1
    [[ "$rstat" == "$cstat" ]] || return 1
    rlink="$(readlink -- "$ref")" || return 1
    clink="$(readlink -- "$cur")" || return 1
    [[ "$rlink" == "$clink" ]]
    return
  fi
  [[ -f "$ref" && -f "$cur" ]] || return 1
  rstat="$(stat -c '%a:%u:%g:%s:%Y' -- "$ref" 2>/dev/null)" || return 1
  cstat="$(stat -c '%a:%u:%g:%s:%Y' -- "$cur" 2>/dev/null)" || return 1
  [[ "$rstat" == "$cstat" ]] && cmp -s -- "$ref" "$cur"
}

# Фиксирует выполненное восстановление: повторный откат проверяет файл, а не
# перезаписывает его вслепую. Ошибки записи и синхронизации - критические:
# без маркера повторный откат мог бы затереть изменения администратора.
journal_mark_restored() {
  local journal="$1" dest="$2" backup="$3"
  if ! journal_append "$journal" restored "$dest" "$backup"; then
    warn "Не удалось записать отметку восстановления ${dest} в журнал ${journal}"
    return 1
  fi
}

# Parse the entire immutable input snapshot BEFORE systemd/filesystem actions.
# These globals describe validated records only; v1 is never upgraded implicitly.
journal_validate() {
  local journal="$1" line action a1 a2 rest i recovery=0 base normalized
  local -a lines=()
  local -A used_backups=() other_paths=()
  RB_JOURNAL_VERSION=1
  declare -ga RB_JOURNAL_ENTRIES=()
  declare -gA RB_RESTORE_BACKUP=() RB_RESTORE_PHASE=()
  [[ -f "$journal" && ! -L "$journal" && -r "$journal" ]] || return 1
  mapfile -t lines <"$journal" || return 1
  # Reject truncated final records, embedded NUL and any mapfile normalization.
  if (( ${#lines[@]} )); then
    cmp -s -- "$journal" <(printf '%s\n' "${lines[@]}") || return 1
  fi
  if [[ "${lines[0]:-}" == "$JOURNAL_V2_HEADER" ]]; then RB_JOURNAL_VERSION=2; fi
  if [[ "${lines[0]:-}" == "$JOURNAL_V3_HEADER" ]]; then
    RB_JOURNAL_VERSION=3
    normalized="$(txn_v3_python validate "$journal")" || return 1
    mapfile -t lines <<<"$normalized"
  fi
  for ((i=0; i<${#lines[@]}; i++)); do
    line="${lines[i]}"
    if [[ "$line" == '# MIFA VPN Basic journal'* ]]; then
      [[ "$i" == 0 && "$line" == "$JOURNAL_V2_HEADER" ]] || return 1
      continue
    fi
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *$'\t'*$'\t'* && "$line" != *$'\r'* ]] || return 1
    action="${line%%$'\t'*}"; rest="${line#*$'\t'}"
    a1="${rest%%$'\t'*}"; a2="${rest#*$'\t'}"
    [[ -n "$a1" && "$a2" != *$'\t'* ]] || return 1
    if [[ "$action" == state ]]; then
      [[ "$RB_JOURNAL_VERSION" == 3 && "$a1" == "$STATE_DIR" && ( "$a2" == created || "$a2" == existing ) ]] || return 1
      RB_JOURNAL_ENTRIES+=("$line")
      continue
    fi
    if [[ "$action" == owned-* ]]; then
      [[ "$RB_JOURNAL_VERSION" == 3 && "$a2" =~ ^[0-9a-f]{32}$ ]] || return 1
      journal_entry_allowed "${action#owned-}" "$a1" '' || return 1
      [[ -z "${RB_RESTORE_BACKUP[$a1]:-}" ]] || return 1
      other_paths["$a1"]=1
      RB_JOURNAL_ENTRIES+=("$line")
      continue
    fi
    journal_entry_allowed "$action" "$a1" "$a2" || return 1
    case "$action" in
      remove|rmdir|chmeta|userdel)
        warn "v1/v2 undo без свидетельства принадлежности: ${action} ${a1}"
        return 1 ;;
    esac
    case "$action" in
      restore)
        (( recovery == 0 )) || return 1
        [[ -z "${RB_RESTORE_BACKUP[$a1]:-}" && -z "${used_backups[$a2]:-}" &&
           -z "${other_paths[$a1]:-}" ]] || return 1
        # The backup must be this destination under one install-* directory.
        [[ "$a2" == *"$a1" ]] || return 1
        base="${a2%"$a1"}"; base="${base#"$BACKUP_ROOT"/}"
        [[ "$base" == install-?* && "$base" != */* ]] || return 1
        RB_RESTORE_BACKUP["$a1"]="$a2"; used_backups["$a2"]=1
        RB_RESTORE_PHASE["$a1"]=pending
        ;;
      restoring|restored)
        recovery=1
        [[ "${RB_RESTORE_BACKUP[$a1]:-}" == "$a2" ]] || return 1
        if [[ "$action" == restoring ]]; then
          [[ "$RB_JOURNAL_VERSION" != 1 && "${RB_RESTORE_PHASE[$a1]}" == pending ]] || return 1
          RB_RESTORE_PHASE["$a1"]=restoring
        else
          if [[ "$RB_JOURNAL_VERSION" != 1 ]]; then
            [[ "${RB_RESTORE_PHASE[$a1]}" == restoring ]] || return 1
          else
            [[ "${RB_RESTORE_PHASE[$a1]}" == pending ]] || return 1
          fi
          RB_RESTORE_PHASE["$a1"]=restored
        fi
        continue
        ;;
      *) (( recovery == 0 )) && [[ -z "$a2" ]] || return 1 ;;
    esac
    RB_JOURNAL_ENTRIES+=("$line")
  done
  if [[ "$RB_JOURNAL_VERSION" == 1 ]]; then
    for a1 in "${!RB_RESTORE_PHASE[@]}"; do
      if [[ "${RB_RESTORE_PHASE[$a1]}" != restored ]]; then
        warn "Неоднозначный v1 restore ${a1}: журнал и данные оставлены для ручного восстановления"
        return 1
      fi
    done
  fi
}

# Restore is deliberately limited to regular files in trusted parent directories.
# Check every parent (not only the final component). These checks and the pinned
# cwd below reduce path substitution; they are NOT a general TOCTOU guarantee
# against a concurrent privileged process replacing directory entries.
txn_restore_parents_safe() {
  local rest="${1#/}" component current='' owner mode
  [[ "$1" == /* && "$1" != *//* && "$1" != */./* && "$1" != *..* ]] || return 1
  while [[ "$rest" == */* ]]; do
    component="${rest%%/*}"; rest="${rest#*/}"; current+="/$component"
    [[ -d "$current" && ! -L "$current" ]] || return 1
    IFS=: read -r owner mode <<<"$(stat -c '%u:%a' -- "$current")"
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
  done
  [[ -n "$rest" ]]
}

txn_restore_types_safe() {
  local dest="$1" backup="$2"
  txn_restore_parents_safe "$dest" && txn_restore_parents_safe "$backup" || return 1
  [[ -f "$backup" && ! -L "$backup" && ! -L "$dest" ]] || return 1
  [[ ! -e "$dest" || -f "$dest" ]]
}

# Independent of cp/mv's exit status. Compare bytes, type, permissions, owner,
# nanosecond mtime and all readable xattrs (including ACLs). Open final files
# without following symlinks; uncertainty or unavailable Python fails closed.
# v1/v2 recovery also requires Python explicitly for independent verification.
txn_restore_matches() {
  local verifier_rc=0
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'MIFA_RESTORE_VERIFIER_ERROR\t127\n' >&2
    return 2
  fi
  if python3 -I - "$1" "$2" <<'PY'
import os, stat, sys

def metadata(fd):
    s = os.fstat(fd)
    if not stat.S_ISREG(s.st_mode):
        raise ValueError("restore expects a regular file")
    attrs = {k: os.getxattr(fd, k) for k in os.listxattr(fd)}
    return (s.st_mode, s.st_uid, s.st_gid, s.st_size, s.st_mtime_ns, attrs)

try:
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(sys.argv[1], flags), "rb") as left, \
         os.fdopen(os.open(sys.argv[2], flags), "rb") as right:
        original = metadata(left.fileno()), metadata(right.fileno())
        if original[0] != original[1]:
            sys.exit(1)
        while True:
            a, b = left.read(1024 * 1024), right.read(1024 * 1024)
            if a != b:
                sys.exit(1)
            if not a:
                break
        if original != (metadata(left.fileno()), metadata(right.fileno())):
            sys.exit(1)
except (OSError, ValueError, AttributeError) as error:
    print("Restore verification failed: " + str(error), file=sys.stderr)
    sys.exit(2)
PY
  then verifier_rc=0; else verifier_rc=$?; fi
  if (( verifier_rc > 1 )); then
    printf 'MIFA_RESTORE_VERIFIER_ERROR\t%s\n' "$verifier_rc" >&2
    return 2
  fi
  return "$verifier_rc"
}

txn_restore_file() (
  local journal="$1" dest="$2" backup="$3" phase="$4" parent leaf staging
  if ! txn_restore_parents_safe "$journal" || ! txn_restore_types_safe "$dest" "$backup"; then
    warn "Небезопасный тип или родительский путь restore: ${dest}, ${backup}"
    return 1
  fi
  parent="$(dirname -- "$dest")"; leaf="${dest##*/}"
  cd -P -- "$parent" || return 1
  [[ "$(pwd -P)" == "$parent" ]] || return 1
  if [[ "$phase" == restored || "$phase" == restoring ]]; then
    if ! txn_restore_matches "$backup" "./$leaf"; then
      warn "Неоднозначный/изменённый restore ${dest}: повторная замена запрещена"
      return 1
    fi
    if [[ "$phase" == restoring ]]; then
      sync "./$leaf" . 2>/dev/null || return 1
      journal_mark_restored "$journal" "$dest" "$backup" || return 1
    fi
    info "Уже восстановлен ${dest}: содержимое и метаданные совпадают с ${backup}"
    return 0
  fi
  [[ "$phase" == pending && "$RB_JOURNAL_VERSION" != 1 ]] || return 1
  command -v python3 >/dev/null 2>&1 || {
    warn 'Для проверки restore нужен python3'
    printf 'MIFA_RESTORE_VERIFIER_ERROR\t127\n' >&2
    return 1
  }
  # Persist intent even if the destination already equals the backup. Any retry
  # after this point is verify-only and cannot replace an administrator's file.
  journal_append "$journal" restoring "$dest" "$backup" || return 1
  test_fault restore_after_intent
  staging="$(mktemp -d -- ./.mifa-restore.XXXXXXXXXX)" || return 1
  info "Staging восстановления: ${parent}/${staging#./}"
  # Never reuse/clean a discovered name; only the newly created private dir.
  # On ANY failure leave it for inspection, with journal+backup retained.
  if ! cp -a -- "$backup" "$staging/payload" ||
     ! txn_restore_matches "$backup" "$staging/payload" ||
     ! sync "$staging/payload" "$staging" . 2>/dev/null; then
    warn "Staging restore сохранён для диагностики: ${parent}/${staging#./}"
    return 1
  fi
  test_fault restore_before_replace
  if ! txn_restore_types_safe "$dest" "$backup" || [[ "$(pwd -P)" != "$parent" ]] ||
     ! mv -fT -- "$staging/payload" "./$leaf"; then
    warn "Замена restore не выполнена; staging сохранён: ${parent}/${staging#./}"
    return 1
  fi
  test_fault restore_after_replace
  if ! txn_restore_types_safe "$dest" "$backup" ||
     ! txn_restore_matches "$backup" "./$leaf" || ! sync "./$leaf" . 2>/dev/null; then
    warn "Результат restore не подтверждён: ${dest}; staging сохранён: ${parent}/${staging#./}"
    return 1
  fi
  journal_mark_restored "$journal" "$dest" "$backup" || return 1
  # No recursive deletion, and only the empty directory created by this call.
  rmdir -- "$staging" || return 1
  info "Восстановлен ${dest} из ${backup}"
)

# Остановка сервиса - критическое действие отката: недоступность systemd и
# неизвестное состояние считаются ошибкой.
txn_stop_unit() {
  local unit="$1" state load
  if ! txn_systemd_available; then
    warn "Не удалось проверить остановку ${unit}: systemd недоступен"
    return 1
  fi
  systemctl stop "$unit" >/dev/null 2>&1 || true
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  case "$state" in
    inactive|failed) return 0 ;;
  esac
  if [[ -z "$state" || "$state" == "unknown" ]]; then
    load="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
    [[ "$load" == "not-found" ]] && return 0
  fi
  warn "Не удалось подтвердить остановку ${unit}: состояние ${state:-неизвестно}"
  return 1
}

# Отключение автозапуска - тоже критическое действие отката.
txn_disable_unit() {
  local unit="$1" state load
  if ! txn_systemd_available; then
    warn "Не удалось проверить отключение ${unit}: systemd недоступен"
    return 1
  fi
  systemctl disable "$unit" >/dev/null 2>&1 || true
  state="$(systemctl show -p UnitFileState --value "$unit" 2>/dev/null || true)"
  case "$state" in
    disabled|masked|masked-runtime|static|indirect|alias|generated|transient) return 0 ;;
  esac
  if [[ -z "$state" || "$state" == "unknown" ]]; then
    load="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
    [[ "$load" == "not-found" ]] && return 0
  fi
  warn "Не удалось подтвердить отключение ${unit}: состояние ${state:-неизвестно}"
  return 1
}

txn_rollback() {
  local journal="${1:-$JOURNAL}" i action a1 a2 entry rmstate=0 rc=0 blocked=0 skipped=0 leftover=""
  local -a entries=()
  set +e
  trap - ERR
  if [[ ! -e "$journal" && ! -L "$journal" ]]; then
    TXN_ACTIVE=0
    return 0
  fi
  # Ошибка чтения журнала: ни одно действие не выполняется, журнал сохраняется.
  if [[ ! -f "$journal" || -L "$journal" || ! -r "$journal" ]]; then
    TXN_ACTIVE=0
    warn "Не удалось прочитать журнал ${journal}: ни одно действие отката не выполнено"
    warn "Журнал и резервные копии в ${BACKUP_ROOT} сохранены; устраните причину и повторите: sudo bash install.sh --rollback"
    return "$RC_ROLLBACK_INCOMPLETE"
  fi
  warn "Откат изменений по журналу ${journal}"
  # Предварительная проверка всех записей. Любая недопустимая или повреждённая
  # запись прерывает откат до изменений системы: журнал сохраняется.
  if ! journal_validate "$journal"; then
    TXN_ACTIVE=0
    warn "Недопустимая запись журнала или неоднозначный протокол: ${journal}"
    warn "Откат прерван до изменений системы: журнал ${journal} сохранён"
    return "$RC_ROLLBACK_INCOMPLETE"
  fi
  for ((i = ${#RB_JOURNAL_ENTRIES[@]} - 1; i >= 0; i--)); do
    entries+=("${RB_JOURNAL_ENTRIES[i]}")
  done
  # Фаза 1: сервис. Пока остановка и отключение не подтверждены, файловые
  # действия не выполняются - независимо от порядка записей в журнале.
  for entry in "${entries[@]}"; do
    IFS=$'\t' read -r action a1 a2 <<<"$entry"
    case "$action" in
      stop)    txn_stop_unit "$a1"    || { rc=1; blocked=1; } ;;
      disable) txn_disable_unit "$a1" || { rc=1; blocked=1; } ;;
    esac
  done
  # Фаза 2: файлы, права, пользователь и каталоги.
  for entry in "${entries[@]}"; do
    IFS=$'\t' read -r action a1 a2 <<<"$entry"
    case "$action" in
      stop|disable|restored) continue ;;
      state) [[ "$a2" != created ]] || rmstate=1; continue ;;
    esac
    if (( blocked )); then
      skipped=$((skipped + 1))
      continue
    fi
    case "$action" in
      owned-*) txn_v3_undo "$journal" "$a2" || rc=1 ;;
      restore)
        txn_restore_file "$journal" "$a1" "$a2" "${RB_RESTORE_PHASE[$a1]}" || rc=1
        ;;
    esac
  done
  if (( blocked )); then
    warn "Откат прерван: ${XRAY_SERVICE} не подтверждён остановленным и отключённым, ${skipped} действий с файлами не выполнялись"
  fi
  # daemon-reload обязателен после изменения unit-файлов.
  if txn_systemd_available; then
    if ! systemctl daemon-reload >/dev/null 2>&1; then
      warn "systemctl daemon-reload завершился с ошибкой: изменения unit-файлов не применены"
      rc=1
    fi
    systemctl reset-failed "$XRAY_SERVICE" >/dev/null 2>&1 || true
  fi
  TXN_ACTIVE=0
  # Каталог состояния после отката должен содержать только журнал.
  if (( rc == 0 && rmstate )) && [[ "$journal" == "$STATE_DIR"/* ]]; then
    if ! leftover="$(find "$STATE_DIR" -mindepth 1 -maxdepth 1 ! -path "$journal" -print -quit 2>/dev/null)"; then
      warn "Не удалось проверить содержимое ${STATE_DIR}"
      rc=1
    elif [[ -n "$leftover" ]]; then
      warn "В ${STATE_DIR} остались посторонние файлы (${leftover}): откат не завершён"
      rc=1
    fi
  fi
  if (( rc != 0 )); then
    warn "Откат завершён не полностью: журнал ${journal} и резервные копии в ${BACKUP_ROOT} сохранены"
    warn "Устраните причину и повторите: sudo bash install.sh --rollback; ручная очистка - docs/RECOVERY.md, раздел 6"
    return "$RC_ROLLBACK_INCOMPLETE"
  fi
  # Журнал удаляется последним; после этого обязательных операций нет.
  if ! rm -f -- "$journal"; then
    warn "Не удалось удалить журнал ${journal}: откат можно повторить"
    return "$RC_ROLLBACK_INCOMPLETE"
  fi
  if [[ "$RB_JOURNAL_VERSION" == 3 ]]; then
    info "Служебный каталог ${STATE_DIR} и маркеры поколений каталогов оставлены; после удаления журнала нет обязательных мутаций"
  fi
  ok "Откат завершён: изменения установщика отменены"
  return 0
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
    if ! txn_rollback "$JOURNAL"; then
      err "Автоматический откат не завершён: журнал ${JOURNAL} и резервные копии в ${BACKUP_ROOT} сохранены"
      err "Устраните причину и повторите: sudo bash install.sh --rollback; ручная очистка - docs/RECOVERY.md, раздел 6"
      rc="$RC_ROLLBACK_INCOMPLETE"
    fi
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
  local journal="${1:-$JOURNAL}"
  if [[ ! -e "$journal" && ! -L "$journal" ]]; then
    ok "Журнал незавершённой установки не найден: откатывать нечего"
    return 0
  fi
  # Существует, но не является обычным читаемым файлом: это ошибка, а не
  # «журнала нет». Возвращаем код 3, журнал не удаляем.
  if [[ ! -f "$journal" || ! -r "$journal" ]]; then
    err "Журнал ${journal} недоступен или не является файлом: откат не выполнен"
    return "$RC_ROLLBACK_INCOMPLETE"
  fi
  if ! txn_rollback "$journal"; then
    err "Откат не завершён: журнал ${journal} и резервные копии в ${BACKUP_ROOT} сохранены"
    err "Устраните причину и повторите: sudo bash install.sh --rollback; ручная очистка - docs/RECOVERY.md, раздел 6"
    return "$RC_ROLLBACK_INCOMPLETE"
  fi
  return 0
}

main() {
  parse_args "$@"
  normalize_inputs
  install_traps
  case "$MODE" in
    rollback)
      require_root
      acquire_lock
      if ! do_rollback_mode; then
        exit "$RC_ROLLBACK_INCOMPLETE"
      fi
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
