# shellcheck shell=bash
# Test-only helpers. Sourcing this file does not mutate filesystem/system state.
RB_PROBE="${TESTS_DIR}/rollback_probe.py"
RB_PROBE_ERRORS=0
RB_INFRA_ERRORS=0
run_probe() {
  local rc=0
  python3 "$RB_PROBE" "$@" || rc=$?
  case "$rc" in
    0|1) ;;
    2)
      RB_PROBE_ERRORS=$((RB_PROBE_ERRORS + 1))
      printf 'MIFA_PROBE_ERROR\t%s\n' "$rc" >&2
      ;;
    *)
      RB_INFRA_ERRORS=$((RB_INFRA_ERRORS + 1))
      printf 'MIFA_PROBE_INFRA_ERROR\t%s\n' "$rc" >&2
      ;;
  esac
  return "$rc"
}
assert_probe() {
  local description="$1" rc=0
  shift
  run_probe "$@" || rc=$?
  case "$rc" in
    0) t_pass "$description" ;;
    1) t_fail "$description" ;;
    *) printf '  ERROR  %s (probe exit %s; not an assertion failure)\n' "$description" "$rc" >&2 ;;
  esac
  # Continue independent data-preservation checks, even after probe errors.
  return 0
}
rollback_summary() {
  local assertion_rc=0
  t_summary || assertion_rc=$?
  if (( RB_INFRA_ERRORS )); then return 3; fi
  if (( RB_PROBE_ERRORS )); then return 2; fi
  return "$assertion_rc"
}
save_snapshot() { run_probe snapshot "$1" >"$2"; }
assert_snapshot() {
  local description="$1"
  shift
  assert_probe "$description" check "$@"
}
path_absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
assert_journal_retained() {
  assert_probe 'journal prefix, type and permissions preserved' \
    journal "$W/journal-before" "$JOURNAL"
}

make_observer() {
  local tool real
  command -v strace >/dev/null || { echo 'strace required for operation coverage' >&2; return 2; }
  mkdir "$W/observer"
  : >"$W/observer/real-tools"
  type -P python3 >"$W/observer/python-real" || return 2
  cat >"$W/observer/systemctl" <<'STOP_WRAPPER'
#!/usr/bin/env bash
set -uo pipefail
"$RB_OBSERVER_SYSTEMCTL" "$@"
rc=$?
if [[ "${1:-}" == stop && "$rc" == 0 ]]; then
  state="$("$RB_OBSERVER_SYSTEMCTL" show -p ActiveState --value xray.service)" || exit 125
  if [[ "$state" == inactive ]]; then
    date +%s.%N >>"$RB_OBSERVER_RUN/stopped" || exit 125
  fi
fi
exit "$rc"
STOP_WRAPPER
  chmod 0755 "$W/observer/systemctl"
  for tool in rm rmdir unlink cp mv install chmod chown userdel ln mkdir touch truncate; do
    real="$(type -P "$tool")" || return 2
    [[ "$real" == /* ]] || return 2
    printf '%s\t%s\n' "$tool" "$real" >>"$W/observer/real-tools"
    {
      printf '#!/usr/bin/env bash\nRB_REAL_TOOL=%q\n' "$real"
      cat <<'WRAPPER'
set -uo pipefail
tool="${0##*/}"
if ! state="$("$RB_OBSERVER_SYSTEMCTL" show -p ActiveState --value xray.service 2>/dev/null)"; then
  state=unknown
fi
printf '%s\t%s\n' "$tool" "${state:-unknown}" >>"$RB_OBSERVER_RUN/events" || exit 125
exec "$RB_REAL_TOOL" "$@"
WRAPPER
    } >"$W/observer/$tool" || return 2
    chmod 0755 "$W/observer/$tool" || return 2
  done
}

observed_rollback() {
  cp -a -- "$JOURNAL" "$W/journal-before" || return 2
  RB_OBSERVER_RUN="$(mktemp -d "$W/observation.XXXXXXXX")" || return 2
  export RB_OBSERVER_RUN RB_OBSERVER_SYSTEMCTL
  : >"$RB_OBSERVER_RUN/events"
  # -ff avoids interleaved unfinished execve lines. Trace the real executables
  # as well as wrappers, so an absolute-path bypass fails observer validation.
  if strace -ff -qq -ttt -s 4096 -e trace=execve,unlinkat,fchmod,fchown -o "$RB_OBSERVER_RUN/trace" \
      env -u MIFA_BASIC_LIB PATH="$W/observer:$PATH" \
      bash "$INSTALL_SH" --rollback >"$W/rollback.out" 2>&1; then
    RB_RC=0
  else
    RB_RC=$?
  fi
  cat "$W/rollback.out"
}
assert_observed() {
  assert_probe 'all mutating commands observed only while inactive' \
    observer "$RB_OBSERVER_RUN" "$W/observer" "$@"
}
