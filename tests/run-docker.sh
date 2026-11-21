#!/usr/bin/env bash
# Disposable Docker tests. No production installer executes on the host.
# Usage: bash tests/run-docker.sh SUITE VERSION [--disposable-linux-vm]
# all = unit, reality, guards, nochange, rollback; NEVER privileged/systemd.
# e2e and rollback-systemd require explicit disposable Linux VM attestation.
# --privileged is NOT host isolation. Never use a workstation/VPN server.
# SSH/TCP Docker endpoints are unsupported, including via Docker contexts.
# Existing MIFA_TEST_XRAY_ZIP_HOST, MIFA_E2E_PUBLIC_SNI and
# MIFA_E2E_ZIP_FOR_INSTALL options remain supported.
# MIFA_TEST_TIMEOUT: seconds per test, default 1800.
# MIFA_ROLLBACK_CASE: optional exact catalog entry, rollback suite only.
set -euo pipefail
die() { echo "ERROR: $*" >&2; exit 2; }
SUITE="${1:-}"
UBUNTU="${2:-}"
CONFIRM="${3:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
case "$UBUNTU" in 22.04|24.04|26.04) ;; *) die 'Ubuntu must be 22.04, 24.04 or 26.04' ;; esac
case "$SUITE" in unit|reality|guards|nochange|rollback|all|rollback-systemd|e2e) ;; *) die "Unknown suite: $SUITE" ;; esac
[[ $# -le 3 && ( -z "$CONFIRM" || "$CONFIRM" == --disposable-linux-vm ) ]] || die 'Unexpected arguments'
TEST_TIMEOUT="${MIFA_TEST_TIMEOUT:-1800}"
[[ "$TEST_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ ]] || die 'Invalid MIFA_TEST_TIMEOUT'
if [[ "${GITHUB_ACTIONS:-false}" == true ]]; then
  [[ "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_OS:-}" == Linux ]] \
    || die 'GitHub Actions tests require GitHub-hosted Linux runners; self-hosted is forbidden'
  if [[ "$SUITE" == e2e || "$SUITE" == rollback-systemd ]]; then
    [[ "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]] \
      || die 'Privileged GitHub Actions suites require workflow_dispatch; push/PR cannot authorize them'
  fi
fi
ROLLBACK_CASE="${MIFA_ROLLBACK_CASE:-}"
if [[ -n "$ROLLBACK_CASE" ]]; then
  [[ "$SUITE" == rollback ]] || die 'MIFA_ROLLBACK_CASE is only valid for the rollback suite'
  case_found=0
  catalog="$(bash "$REPO/tests/rollback_regressions.sh" --list)" || die 'Cannot list regression cases'
  while IFS= read -r entry; do
    if [[ "$entry" == "$ROLLBACK_CASE" ]]; then case_found=1; break; fi
  done <<<"$catalog"
  (( case_found )) || die "Unknown rollback case: $ROLLBACK_CASE"
fi
command -v docker >/dev/null || die 'Docker unavailable; automatic installation is disabled'
command -v timeout >/dev/null || die 'GNU-compatible timeout required'

# Read CLI metadata before contacting a daemon. Reject ambiguous overrides.
[[ -z "${DOCKER_HOST:-}" || -z "${DOCKER_CONTEXT:-}" ]] || die 'Set only one of DOCKER_HOST and DOCKER_CONTEXT'
if [[ -n "${DOCKER_HOST:-}" ]]; then
  endpoint="$DOCKER_HOST"
  context='DOCKER_HOST override'
else
  context="${DOCKER_CONTEXT:-}"
  if [[ -z "$context" ]]; then
    context="$(docker context show)" || die 'Cannot determine Docker context'
  fi
  endpoint="$(docker context inspect "$context" --format '{{.Endpoints.docker.Host}}')" \
    || die 'Cannot inspect Docker context'
fi
case "$endpoint" in
  unix:///*|npipe:////./pipe/*) ;;
  *) die "Remote/unsupported Docker endpoint rejected: $endpoint (context: $context)" ;;
esac
if [[ "${GITHUB_ACTIONS:-false}" == true && "$endpoint" != unix:///var/run/docker.sock ]]; then
  die "GitHub Actions requires the local default Docker socket; got: $endpoint"
fi
echo "Docker context: $context; pinned endpoint: $endpoint"
DOCKER=(env -u DOCKER_HOST -u DOCKER_CONTEXT docker --host "$endpoint")
if [[ "$SUITE" == e2e || "$SUITE" == rollback-systemd ]]; then
  [[ "$CONFIRM" == --disposable-linux-vm ]] \
    || die 'Privileged suite requires --disposable-linux-vm: attest this is a disposable Linux VM'
  [[ "$(uname -s)" == Linux && "$endpoint" == unix:///* ]] \
    || die 'Privileged suites require a Linux VM shell and local Unix Docker socket'
  echo 'WARNING: privileged containers can affect the Docker host; VM confirmation is an operator attestation, not an isolation guarantee.' >&2
fi
daemon_os="$(timeout 30s "${DOCKER[@]}" info --format '{{.OSType}}')" || die 'Docker daemon unavailable'
[[ "$daemon_os" == linux ]] || die 'Linux Docker engine required'

TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mifa-docker.XXXXXXXX")" || die 'Cannot create runner state'
RUN_ID="${TASK_TMP##*/}"
echo "Test run label: mifa.test-run=$RUN_ID"
CONTAINERS=()
CONTAINER_N=0
CURRENT_CONTAINER=''
PLAIN_IMAGE=''
SYSTEMD_IMAGE=''
cleanup_error() {
  # Machine-readable evidence in console.log; keep every failed attempt.
  printf 'MIFA_RUNNER_CLEANUP_ERROR\t%s\t%s\n' "$1" "$2" >&2
}
cleanup() {
  local original_rc=$? name id cleanup_failed=0 cleanup_rc=0
  trap - EXIT HUP INT TERM
  for name in "${CONTAINERS[@]}"; do
    # Names are registered BEFORE create; labels verify ownership before rm.
    if id="$(timeout 30s "${DOCKER[@]}" ps -aq --filter "name=^/${name}$" \
        --filter "label=mifa.test-run=$RUN_ID")"; then
      :
    else
      cleanup_rc=$?
      cleanup_error exit-inspect "$cleanup_rc"
      echo "ERROR: cannot inspect cleanup target $name; inspect Docker manually" >&2
      cleanup_failed=1
      continue
    fi
    [[ -n "$id" ]] || continue
    if timeout 30s "${DOCKER[@]}" rm -f "$id" >/dev/null; then
      :
    else
      cleanup_rc=$?
      cleanup_error exit-remove "$cleanup_rc"
      echo "ERROR: failed to remove test container $name ($id)" >&2
      cleanup_failed=1
    fi
  done
  if (( cleanup_failed )); then
    echo "Runner state retained: $TASK_TMP; run label: mifa.test-run=$RUN_ID" >&2
    (( original_rc != 0 )) || original_rc="$cleanup_rc"
  else
    # Known files only, never a recursive delete of a computed directory.
    for name in plain.iid systemd.iid; do
      if rm -f -- "$TASK_TMP/$name"; then :; else
        cleanup_rc=$?; cleanup_failed=1; cleanup_error state-file "$cleanup_rc"
      fi
    done
    if rmdir -- "$TASK_TMP"; then :; else
      cleanup_rc=$?; cleanup_failed=1; cleanup_error state-directory "$cleanup_rc"
    fi
    if (( cleanup_failed && original_rc == 0 )); then original_rc="$cleanup_rc"; fi
  fi
  exit "$original_rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

build() {
  local target="$1" image_id
  if ! timeout 1200s "${DOCKER[@]}" build --quiet --target "$target" \
      --build-arg "UBUNTU=$UBUNTU" --iidfile "$TASK_TMP/$target.iid" \
      -f "$REPO/tests/docker/Dockerfile" "$REPO/tests/docker"; then
    die "Image build failed ($target/$UBUNTU); no cached-image fallback"
  fi
  image_id="$(cat "$TASK_TMP/$target.iid")" || die 'Missing build image ID'
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'Invalid build image ID'
  case "$target" in plain) PLAIN_IMAGE="$image_id" ;; systemd) SYSTEMD_IMAGE="$image_id" ;; esac
}
zip_mount=()
zip_env=()
if [[ -n "${MIFA_TEST_XRAY_ZIP_HOST:-}" ]]; then
  [[ -f "$MIFA_TEST_XRAY_ZIP_HOST" ]] || die 'Xray archive does not exist'
  zip_host="$(cd "$(dirname "$MIFA_TEST_XRAY_ZIP_HOST")" && pwd)/$(basename "$MIFA_TEST_XRAY_ZIP_HOST")" \
    || die 'Cannot resolve Xray archive'
  [[ "$zip_host" != *,* ]] || die 'Comma in bind-mount path is unsupported'
  zip_mount=(--mount "type=bind,src=$zip_host,dst=/xray/xray.zip,readonly")
  zip_env=(-e MIFA_TEST_XRAY_ZIP=/xray/xray.zip)
fi
[[ "$REPO" != *,* ]] || die 'Comma in repository bind-mount path is unsupported'
repo_mount=(--mount "type=bind,src=$REPO,dst=/src,readonly")

create_container() {
  CONTAINER_N=$((CONTAINER_N + 1))
  CURRENT_CONTAINER="${RUN_ID}-${CONTAINER_N}"
  CONTAINERS+=("$CURRENT_CONTAINER")
  timeout 60s "${DOCKER[@]}" create --name "$CURRENT_CONTAINER" \
    --label "mifa.test-run=$RUN_ID" "${repo_mount[@]}" "$@" >/dev/null \
    || die 'Container creation failed'
}
remove_container() {
  local owned_id rc=0
  owned_id="$(timeout 30s "${DOCKER[@]}" ps -aq --filter "name=^/${CURRENT_CONTAINER}$" \
    --filter "label=mifa.test-run=$RUN_ID")" || rc=$?
  if (( rc != 0 )); then cleanup_error inspect "$rc"; return "$rc"; fi
  if [[ -z "$owned_id" || "$owned_id" == *$'\n'* ]]; then
    echo "ERROR: missing/ambiguous owned container: $CURRENT_CONTAINER" >&2
    cleanup_error ownership 2
    return 2
  fi
  timeout 30s "${DOCKER[@]}" rm -f "$owned_id" >/dev/null || rc=$?
  if (( rc != 0 )); then
    echo "ERROR: container cleanup failed: $CURRENT_CONTAINER" >&2
    cleanup_error remove "$rc"
  fi
  return "$rc"
}
finish_test() {
  local test_rc="$1" cleanup_rc=0
  # Emit BEFORE cleanup; a failed cleanup must not erase the original test code.
  printf 'MIFA_RUNNER_TEST_EXIT\t%s\t%s\n' "$CURRENT_CONTAINER" "$test_rc"
  remove_container || cleanup_rc=$?
  if (( cleanup_rc != 0 )); then
    # Stop creating containers; EXIT still retries cleanup and records failures.
    if (( test_rc != 0 )); then exit "$test_rc"; else exit "$cleanup_rc"; fi
  fi
  return "$test_rc"
}
run_attached() {
  local rc=0 code
  create_container "$@"
  timeout --kill-after=10s "${TEST_TIMEOUT}s" "${DOCKER[@]}" start -a "$CURRENT_CONTAINER" || rc=$?
  if (( rc == 0 )); then
    code="$(timeout 30s "${DOCKER[@]}" inspect --format '{{.State.ExitCode}}' "$CURRENT_CONTAINER")" \
      || die 'Cannot read test exit status'
    [[ "$code" =~ ^[0-9]+$ ]] || die 'Invalid container exit status'
    rc="$code"
  fi
  finish_test "$rc"
}
run_plain() {
  local script="$1"
  [[ -n "$PLAIN_IMAGE" ]] || build plain
  run_attached -e MIFA_TEST_DISPOSABLE=1 -e MIFA_NOCHANGE_EXPECT_SANDBOX \
    "${zip_env[@]}" "${zip_mount[@]}" "$PLAIN_IMAGE" bash "/src/tests/$script"
}
run_unit() {
  local rc=0
  run_plain unit.sh || rc=1
  run_attached --user 65534:65534 -e HOME=/tmp "${zip_env[@]}" "${zip_mount[@]}" \
    "$PLAIN_IMAGE" bash /src/tests/unit.sh || rc=1
  return "$rc"
}
run_rollback() {
  local test_case rc=0 case_rc cases
  [[ -n "$PLAIN_IMAGE" ]] || build plain
  # --list reads the catalog only, without sourcing install.sh or mutations.
  cases="$(bash "$REPO/tests/rollback_regressions.sh" --list)" || die 'Cannot list regression cases'
  [[ -n "$cases" ]] || die 'Empty regression catalog'
  if [[ -n "$ROLLBACK_CASE" ]]; then cases="$ROLLBACK_CASE"; fi
  while IFS= read -r test_case; do
    echo "### rollback/$test_case on Ubuntu $UBUNTU (fresh unprivileged container)"
    case_rc=0
    run_attached --network none -e MIFA_TEST_DISPOSABLE=1 \
      "$PLAIN_IMAGE" bash /src/tests/rollback_regressions.sh "$test_case" || case_rc=$?
    echo "### rollback/$test_case exit code: $case_rc"
    if [[ -n "$ROLLBACK_CASE" ]]; then return "$case_rc"; fi
    if (( case_rc != 0 )); then rc=1; fi
  done <<<"$cases"
  return "$rc"
}
run_systemd() {
  local script="$1" state='' i rc=0
  local -a options=() test_env=(-e MIFA_TEST_DISPOSABLE=1)
  [[ "$CONFIRM" == --disposable-linux-vm && ( "$SUITE" == e2e || "$SUITE" == rollback-systemd ) ]] \
    || die 'Privileged test not explicitly authorized for this invocation'
  build systemd
  if [[ "$script" == rollback_systemd.sh ]]; then
    options+=(--network none)
  else
    options+=("${zip_mount[@]}")
    test_env+=(-e "MIFA_E2E_PUBLIC_SNI=${MIFA_E2E_PUBLIC_SNI:-}")
    if [[ "${MIFA_E2E_ZIP_FOR_INSTALL:-0}" == 1 ]]; then
      test_env+=("${zip_env[@]}")
    elif [[ -n "${MIFA_TEST_XRAY_ZIP_HOST:-}" ]]; then
      test_env+=(-e MIFA_TEST_XRAY_ZIP_AUX=/xray/xray.zip)
    fi
  fi
  # Unsupported engines fail, with NO fallback to writable host cgroup mounts.
  # Privileged mode still exposes the Docker host; use a disposable VM.
  create_container --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock \
    "${options[@]}" "$SYSTEMD_IMAGE"
  timeout 30s "${DOCKER[@]}" start "$CURRENT_CONTAINER" >/dev/null || die 'systemd container start failed'
  for ((i = 0; i < 30; i++)); do
    state="$(timeout 5s "${DOCKER[@]}" exec "$CURRENT_CONTAINER" systemctl is-system-running 2>/dev/null || true)"
    [[ "$state" == running || "$state" == degraded ]] && break
    sleep 1
  done
  if [[ "$state" != running && "$state" != degraded ]]; then
    timeout 10s "${DOCKER[@]}" logs "$CURRENT_CONTAINER" >&2 || true
    die "systemd not ready (${state:-unknown}); test was not executed"
  fi
  timeout --kill-after=10s "${TEST_TIMEOUT}s" "${DOCKER[@]}" exec "${test_env[@]}" \
    "$CURRENT_CONTAINER" bash "/src/tests/$script" || rc=$?
  if (( rc != 0 )); then
    timeout 10s "${DOCKER[@]}" exec "$CURRENT_CONTAINER" journalctl -u xray -n 40 --no-pager 2>&1 \
      | sed -E 's/("privateKey": ")[^"]+/\1<hidden>/' >&2 || true
  fi
  finish_test "$rc"
}
case "$SUITE" in
  unit) run_unit ;;
  reality) run_plain reality_probe.sh ;;
  guards) run_plain guards.sh ;;
  nochange) run_plain nochange.sh ;;
  rollback) run_rollback ;;
  rollback-systemd) run_systemd rollback_systemd.sh ;;
  e2e) run_systemd e2e_systemd.sh ;;
  all)
    echo 'all runs ONLY unprivileged suites; systemd suites require separate VM-confirmed invocations'
    rc=0
    run_unit || rc=1
    run_plain reality_probe.sh || rc=1
    run_plain guards.sh || rc=1
    run_plain nochange.sh || rc=1
    run_rollback || rc=1
    exit "$rc"
    ;;
esac
