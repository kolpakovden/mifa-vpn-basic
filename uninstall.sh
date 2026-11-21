#!/usr/bin/env bash
# MIFA VPN Basic - удаление установки, созданной install.sh.
# Перед удалением конфиг и данные клиента копируются в /var/backups/mifa-vpn-basic.
set -Eeuo pipefail
umask 077

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

ASSUME_YES=0
FORCE=0
MODE=""
BACKUP_DIR=""

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
MIFA VPN Basic - удаление

Использование:
  sudo bash uninstall.sh [--yes] [--force]

  -y, --yes   Не спрашивать подтверждение
  --force     Удалить Xray без манифеста Basic (установки Basic до 1.1 и
              похожие на них). Перед удалением создаётся резервная копия.
  -h, --help  Эта справка

Удаляются: ${XRAY_SERVICE}, ${XRAY_BIN}, ${XRAY_CONF_DIR},
${XRAY_UNIT}, ${STATE_DIR} и пользователь ${XRAY_USER}, если его создал Basic.
Резервная копия: ${BACKUP_ROOT}/uninstall-<время>/
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    --force)  FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Неизвестный аргумент: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "${EUID}" -ne 0 ]]; then
  err "Запусти с sudo или от root"
  exit 1
fi

manifest_value() {
  sed -n "s/^$1=//p" "$MANIFEST" 2>/dev/null | sed -n '1p'
}

xray_present() {
  [[ -e "$XRAY_BIN" || -e "$XRAY_CONF_DIR" || -e "$XRAY_UNIT" ]] \
    || systemctl is-active --quiet "$XRAY_SERVICE" 2>/dev/null
}

if [[ -e "$JOURNAL" ]]; then
  die "Найдена незавершённая установка (${JOURNAL}). Сначала выполните: sudo bash install.sh --rollback"
fi

if [[ -f "$MANIFEST" ]]; then
  MODE="managed"
elif xray_present; then
  if command -v dpkg-query >/dev/null 2>&1 \
     && dpkg-query -W -f='${Status}' xray 2>/dev/null | grep -q 'install ok installed'; then
    die "Xray установлен APT-пакетом xray. Удалите его менеджером пакетов: sudo apt-get purge xray"
  fi
  if (( FORCE )); then
    MODE="legacy"
    warn "Манифест Basic не найден: удаление в режиме --force (как у Basic до версии 1.1)"
  else
    die "Манифест MIFA Basic (${MANIFEST}) не найден: Xray установлен не этой версией Basic. Чужой Xray не удаляется. Для установок Basic до 1.1 используйте --force (будет создана резервная копия)."
  fi
else
  ok "Установка MIFA Basic не найдена: удалять нечего"
  exit 0
fi

if (( ! ASSUME_YES )); then
  if [[ ! -t 0 ]]; then
    die "Нет терминала для подтверждения: добавьте --yes"
  fi
  read -r -p "Удалить Xray и конфигурацию (резервная копия будет сохранена)? (y/N): " CONFIRM || CONFIRM=""
  case "${CONFIRM:-N}" in
    y|Y|yes|д|Д|да) ;;
    *) info "Отменено."; exit 0 ;;
  esac
fi

BACKUP_DIR="${BACKUP_ROOT}/uninstall-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$BACKUP_ROOT"
install -d -m 0700 "$BACKUP_DIR"

backup() {
  local p="$1" dest
  [[ -e "$p" || -L "$p" ]] || return 0
  dest="${BACKUP_DIR}${p}"
  mkdir -p -- "$(dirname "$dest")"
  cp -a -- "$p" "$dest"
}

info "Резервная копия: ${BACKUP_DIR}"
backup "$XRAY_CONF_DIR"
backup "$XRAY_UNIT"
backup "$CLIENT_FILE"
backup "$MANIFEST"
if [[ "$MODE" == "legacy" ]]; then
  backup /etc/xray
  backup /etc/systemd/system/xray@.service
fi
if [[ -e "$XRAY_CONF" && ! -e "${BACKUP_DIR}${XRAY_CONF}" ]]; then
  die "Резервная копия ${XRAY_CONF} не создана: удаление остановлено, ничего не удалено"
fi
ok "Резервная копия создана"

info "Останавливаем сервис..."
systemctl stop "$XRAY_SERVICE" 2>/dev/null || true
systemctl disable "$XRAY_SERVICE" >/dev/null 2>&1 || true

info "Удаляем файлы..."
rm -f -- "$XRAY_UNIT"
rm -f -- "$XRAY_BIN"
rm -f -- "$XRAY_CONF"
if [[ "$MODE" == "legacy" ]]; then
  rm -rf -- "$XRAY_CONF_DIR"
  rm -f -- /etc/systemd/system/xray@.service
  rm -rf -- /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
elif [[ -d "$XRAY_CONF_DIR" ]]; then
  rmdir -- "$XRAY_CONF_DIR" 2>/dev/null || warn "${XRAY_CONF_DIR} содержит посторонние файлы и оставлен (копия в резервной копии)"
fi
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed "$XRAY_SERVICE" 2>/dev/null || true

if [[ "$MODE" == "managed" && "$(manifest_value user_created)" == "1" ]]; then
  if id -u "$XRAY_USER" >/dev/null 2>&1; then
    userdel "$XRAY_USER" 2>/dev/null || warn "Не удалось удалить пользователя ${XRAY_USER}"
  fi
fi

rm -f -- "$CLIENT_FILE" "$MANIFEST"
rmdir -- "$STATE_DIR" 2>/dev/null || true

ok "Удаление завершено."
echo
echo "Резервная копия конфига и данных клиента: ${BACKUP_DIR}"
echo "Восстановление прежних ключей и ссылки после новой установки: docs/RECOVERY.md"
if [[ "$MODE" == "legacy" ]]; then
  echo "Логи старых версий в /var/log/xray не удалялись."
fi
