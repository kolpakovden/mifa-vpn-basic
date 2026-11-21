#!/usr/bin/env bash
# Запуск тестов в одноразовых Docker-контейнерах Ubuntu.
#
#   tests/run-docker.sh SUITE UBUNTU
#   SUITE:  unit | reality | guards | nochange | e2e | all
#   UBUNTU: 22.04 | 24.04 | 26.04
#
# Переменные:
#   MIFA_TEST_XRAY_ZIP_HOST  путь к Xray-linux-64.zip на хосте. Без него
#                            unit/guards/nochange пропускают сверку с настоящим
#                            xray, а e2e скачивает архив установщиком.
#   MIFA_E2E_PUBLIC_SNI      домен публичной REALITY-цели для дополнительного
#                            e2e-сценария (нужен выход в интернет).
#   MIFA_E2E_ZIP_FOR_INSTALL=1  e2e использует MIFA_TEST_XRAY_ZIP_HOST вместо загрузки.
set -euo pipefail

SUITE="${1:-}"
UBUNTU="${2:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

case "$UBUNTU" in
  22.04|24.04|26.04) ;;
  *) echo "Укажите версию Ubuntu: 22.04, 24.04 или 26.04" >&2; exit 2 ;;
esac

build() { # target
  docker build --quiet --target "$1" --build-arg "UBUNTU=${UBUNTU}" \
    -t "mifa-basic-test:${1}-${UBUNTU}" -f "${REPO}/tests/docker/Dockerfile" "${REPO}/tests/docker" >/dev/null
}

zip_mount=()
zip_env=()
if [[ -n "${MIFA_TEST_XRAY_ZIP_HOST:-}" ]]; then
  zip_host="$(cd "$(dirname "$MIFA_TEST_XRAY_ZIP_HOST")" && pwd)/$(basename "$MIFA_TEST_XRAY_ZIP_HOST")"
  zip_mount=(-v "${zip_host}:/xray/xray.zip:ro")
  zip_env=(-e MIFA_TEST_XRAY_ZIP=/xray/xray.zip)
fi

run_plain() { # скрипт, [docker-опции...]
  local script="$1"
  shift
  build plain
  echo "### ${script} на Ubuntu ${UBUNTU} (контейнер без systemd)"
  docker run --rm -e MIFA_TEST_DISPOSABLE=1 -e MIFA_NOCHANGE_EXPECT_SANDBOX "${zip_env[@]}" "$@" \
    -v "${REPO}:/src:ro" "${zip_mount[@]}" "mifa-basic-test:plain-${UBUNTU}" \
    bash "/src/tests/${script}"
}

run_unit() {
  run_plain unit.sh
  echo "### unit.sh от непривилегированного пользователя"
  docker run --rm --user 65534:65534 -e HOME=/tmp "${zip_env[@]}" \
    -v "${REPO}:/src:ro" "${zip_mount[@]}" "mifa-basic-test:plain-${UBUNTU}" \
    bash /src/tests/unit.sh
}

run_e2e() {
  local cid rc=0 i state
  build systemd
  echo "### e2e_systemd.sh на Ubuntu ${UBUNTU} (контейнер с systemd)"
  local -a env=(-e MIFA_TEST_DISPOSABLE=1 -e "MIFA_E2E_PUBLIC_SNI=${MIFA_E2E_PUBLIC_SNI:-}")
  if [[ "${MIFA_E2E_ZIP_FOR_INSTALL:-0}" == "1" ]]; then
    env+=("${zip_env[@]}")
  elif [[ -n "${MIFA_TEST_XRAY_ZIP_HOST:-}" ]]; then
    env+=(-e MIFA_TEST_XRAY_ZIP_AUX=/xray/xray.zip)
  fi
  cid="$(docker run -d --privileged --cgroupns=host \
          -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
          -v "${REPO}:/src:ro" "${zip_mount[@]}" "mifa-basic-test:systemd-${UBUNTU}")"
  for ((i = 0; i < 60; i++)); do
    state="$(docker exec "$cid" systemctl is-system-running 2>/dev/null || true)"
    [[ "$state" == "running" || "$state" == "degraded" ]] && break
    sleep 1
  done
  echo "systemd в контейнере: ${state:-unknown}"
  docker exec "${env[@]}" "$cid" bash /src/tests/e2e_systemd.sh || rc=$?
  if (( rc != 0 )); then
    echo "### journalctl -u xray (последние строки)"
    docker exec "$cid" journalctl -u xray -n 40 --no-pager 2>&1 | sed -E 's/("privateKey": ")[^"]+/\1<hidden>/' || true
  fi
  docker rm -f "$cid" >/dev/null
  return "$rc"
}

case "$SUITE" in
  unit)     run_unit ;;
  reality)  run_plain reality_probe.sh ;;
  guards)   run_plain guards.sh ;;
  nochange) run_plain nochange.sh ;;
  e2e)      run_e2e ;;
  all)
    rc=0
    run_unit || rc=1
    run_plain reality_probe.sh || rc=1
    run_plain guards.sh || rc=1
    run_plain nochange.sh || rc=1
    run_e2e || rc=1
    exit "$rc"
    ;;
  *) echo "Неизвестный набор: ${SUITE} (unit, reality, guards, nochange, e2e, all)" >&2; exit 2 ;;
esac
