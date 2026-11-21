#!/usr/bin/env bash
# --preflight, --plan и --dry-run не меняют систему: сравнение снимков
# файловой системы, учётных записей и unit-файлов до и после запуска.
# Только для одноразового контейнера (tests/run-docker.sh nochange).
#
# MIFA_NOCHANGE_ARGS - аргументы установщика (по умолчанию быстрый target без сети).
# MIFA_NOCHANGE_EXPECT_RC - ожидаемый код dry-run (по умолчанию не проверяется).
set -uo pipefail
T_NAME="nochange"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
require_disposable

mapfile -t XSRC < <(xray_src_args)
if [[ -n "${MIFA_NOCHANGE_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  ARGS=(${MIFA_NOCHANGE_ARGS})
else
  grep -q 'guard.test' /etc/hosts || echo '127.0.0.1 guard.test' >>/etc/hosts
  ARGS=(--sni guard.test --server-address 127.0.0.1)
fi
ARGS+=("${XSRC[@]}")

S="$(mktemp -d)"
for mode in --preflight --plan --dry-run; do
  t_section "Режим ${mode}"
  tmp_before="$(find /tmp -maxdepth 1 -name 'mifa-basic.*' | wc -l)"
  fs_snapshot >"${S}/before"
  out="$(bash "$INSTALL_SH" "$mode" "${ARGS[@]}" 2>&1)"
  rc=$?
  fs_snapshot >"${S}/after"
  if diff -u "${S}/before" "${S}/after" >"${S}/diff"; then
    t_pass "${mode}: файловая система, пользователи и unit-файлы не изменились"
  else
    t_fail "${mode}: обнаружены изменения"
    sed -n '1,40p' "${S}/diff" | sed 's/^/        | /'
  fi
  assert_eq "${mode}: временный каталог удалён" "$tmp_before" "$(find /tmp -maxdepth 1 -name 'mifa-basic.*' | wc -l)"
  assert_contains "${mode}: preflight выполнен" "$out" "Итог preflight"
  if [[ "$mode" != "--preflight" ]]; then
    assert_contains "${mode}: план выведен" "$out" "План установки"
  fi
  if [[ "$mode" == "--dry-run" && ( " ${ARGS[*]} " == *" --xray-zip "* || "${MIFA_NOCHANGE_EXPECT_SANDBOX:-0}" == "1" ) ]]; then
    assert_contains "dry-run: xray run -test выполнен" "$out" "xray run -test: конфиг"
    assert_contains "dry-run: завершён" "$out" "Dry-run завершён"
  fi
  if [[ -n "${MIFA_NOCHANGE_EXPECT_RC:-}" ]]; then
    assert_rc "${mode}: код возврата" "$MIFA_NOCHANGE_EXPECT_RC" "$rc"
  fi
  if (( T_FAIL )); then
    printf '%s\n' "$out" | sed -n '1,60p' | sed 's/^/        > /'
  fi
done
rm -rf "$S"
t_summary
