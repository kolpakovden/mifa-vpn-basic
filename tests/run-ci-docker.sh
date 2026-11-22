#!/usr/bin/env bash
# Capture a Docker invocation without converting baseline failures to success.
# Usage: SUITE UBUNTU NEW_OUTPUT_DIRECTORY [--disposable-linux-vm]
# Logs contain console diagnostics, not copies of VPN configs/account databases.
set -euo pipefail
[[ $# == 3 || $# == 4 ]] || { echo 'Expected suite, Ubuntu, output directory, optional VM confirmation' >&2; exit 2; }
suite="$1" ubuntu="$2" output="$3" confirmation="${4:-}"
case "$suite" in rollback|rollback-systemd|e2e) ;; *) exit 2 ;; esac
[[ "$suite" != rollback || -n "${MIFA_ROLLBACK_CASE:-}" ]] \
  || { echo 'CI reporting requires one explicit MIFA_ROLLBACK_CASE; use run-docker.sh for the full suite' >&2; exit 2; }
case "$ubuntu" in 22.04|24.04|26.04) ;; *) exit 2 ;; esac
scenario="${MIFA_ROLLBACK_CASE:-$suite}"
[[ "$scenario" =~ ^[a-z][a-z0-9-]*$ ]] || exit 2
[[ -z "$confirmation" || "$confirmation" == --disposable-linux-vm ]] || exit 2
command -v python3 >/dev/null || { echo 'Python 3 required for CI evidence reporting' >&2; exit 2; }
# Refuse reuse/symlinks rather than overwriting an earlier run's evidence.
mkdir -- "$output"
expected=FAIL
case "$scenario" in
  control-remove|control-restore|e2e) expected=PASS ;;
  v3-*) expected=NOT_ESTABLISHED ;;
esac
printf 'Ubuntu=%s scenario=%s expected-before-fixes=%s\n' "$ubuntu" "$scenario" "$expected"
args=("$suite" "$ubuntu")
if [[ -n "$confirmation" ]]; then args+=("$confirmation"); fi
set +e
bash "$(dirname "$0")/run-docker.sh" "${args[@]}" 2>&1 | tee "$output/console.log"
codes=("${PIPESTATUS[@]}")
set -e
# Keep both pipeline exit codes. The reporter returns the original failure;
# it also rejects a zero exit without evidence that assertions completed.
exec python3 "$(dirname "$0")/ci_result.py" "$suite" "$ubuntu" "$scenario" "$output" "${codes[@]}"
