#!/usr/bin/env bash
# P1-5 integration regression, only in a fresh disposable systemd container.
# Run IN A DISPOSABLE LINUX VM ONLY:
# bash tests/run-docker.sh rollback-systemd 24.04 --disposable-linux-vm
# Uses a harmless sleep fixture as xray.service; no Xray/network/download needed.
# Boot activation is modelled by a real systemctl start after SIGKILL. This is
# NOT a full reboot/power-loss test and does not validate filesystem durability.
set -Eeuo pipefail
T_NAME="rollback-systemd"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/rollback_test_lib.sh
. "${TESTS_DIR}/rollback_test_lib.sh"
require_disposable
[[ "$(uname -s)" == Linux && -f /.dockerenv && -d /run/systemd/system ]] \
  || { echo 'Disposable Linux Docker container with systemd required' >&2; exit 2; }

for p in /usr/local/bin/xray /usr/local/etc/xray /etc/systemd/system/xray.service /var/lib/mifa-vpn-basic; do
  [[ ! -e "$p" && ! -L "$p" ]] || { echo "Fresh container required: $p exists" >&2; exit 2; }
done
if getent passwd xray >/dev/null || getent group xray >/dev/null; then
  echo 'Fresh container required: xray account/group exists' >&2
  exit 2
fi
[[ "$(systemctl show -p LoadState --value xray.service)" == not-found ]] \
  || { echo 'Fresh container required: xray unit is already loaded' >&2; exit 2; }

W="$(mktemp -d)"
export MIFA_RB_TEST_DIR="$W"
printf '#!/bin/sh\nexec /usr/bin/sleep 600\n' >"$W/xray-fixture"
install -d -m 0700 /var/lib/mifa-vpn-basic /usr/local/etc/xray
printf 'original manifest\n' >/var/lib/mifa-vpn-basic/manifest
chmod 0600 /var/lib/mifa-vpn-basic/manifest
save_snapshot /var/lib/mifa-vpn-basic/manifest "$W/original-manifest.json"
printf 'transaction manifest\n' >"$W/manifest"

# A separate bash process is important: test_fault kills $$, not a subshell PID.
# Only the fixture service may be stopped by cleanup, after the fresh-host gate.
trap 'systemctl stop xray.service >/dev/null 2>&1 || true' EXIT
if bash -c '
  export MIFA_BASIC_LIB=1
  . "$INSTALL_SH"
  txn_begin
  txn_create_user
  txn_mkdir "$XRAY_CONF_DIR" 0750 root root
  txn_mkdir "$XRAY_CONF_DIR/child" 0750 root root
  txn_install_file "$MIFA_RB_TEST_DIR/manifest" "$MANIFEST" 0600 root root
  txn_install_file "$MIFA_RB_TEST_DIR/manifest" "$XRAY_CONF" 0640 root root
  txn_install_file "$MIFA_RB_TEST_DIR/xray-fixture" "$XRAY_BIN" 0755 root root
  render_unit >"$MIFA_RB_TEST_DIR/xray.service"
  txn_install_file "$MIFA_RB_TEST_DIR/xray.service" "$XRAY_UNIT" 0644 root root
  systemctl daemon-reload
  journal_undo disable "$XRAY_SERVICE"
  systemctl enable "$XRAY_SERVICE"
  MIFA_BASIC_TEST_MODE=1
  MIFA_BASIC_TEST_FAIL_AT=after_enable:kill
  test_fault after_enable
' >"$W/prepare.out" 2>&1; then prepare_rc=0; else prepare_rc=$?; fi
if [[ "$prepare_rc" != 137 ]]; then
  cat "$W/prepare.out" >&2
  echo "SETUP FAILED: expected SIGKILL/137, got $prepare_rc" >&2
  exit 2
fi
JOURNAL=/var/lib/mifa-vpn-basic/journal.inprogress
save_snapshot /var/backups/mifa-vpn-basic "$W/backup-before.json"
[[ -f "$JOURNAL" && -f /usr/local/bin/xray ]] || exit 2
if grep -q $'^stop\t' "$JOURNAL"; then
  echo 'SETUP FAILED: unexpected stop record' >&2
  exit 2
fi
[[ "$(systemctl is-enabled xray.service)" == enabled ]] || exit 2

# Simulate the activation that would occur on the next boot, without adding a
# stop record. Require a real running process, not just an enabled unit file.
systemctl start xray.service
systemctl is-active --quiet xray.service || exit 2
main_pid="$(systemctl show -p MainPID --value xray.service)"
[[ "$main_pid" =~ ^[1-9][0-9]*$ && -d "/proc/$main_pid" ]] || exit 2

RB_OBSERVER_SYSTEMCTL="$(type -P systemctl)"
make_observer
observed_rollback
assert_rc 'rollback after activation returns success' 0 "$RB_RC"
assert_observed rm rmdir chmod chown cp mv userdel
if state="$(systemctl show -p ActiveState --value xray.service)"; then state_rc=0; else state_rc=$?; fi
assert_rc 'service state query succeeds' 0 "$state_rc"
assert_eq 'fixture service is inactive' inactive "$state"
assert_false 'original service process gone' test -d "/proc/$main_pid"
if load="$(systemctl show -p LoadState --value xray.service)"; then load_rc=0; else load_rc=$?; fi
assert_rc 'unit load query succeeds' 0 "$load_rc"
assert_eq 'removed unit is not loaded' not-found "$load"
assert_true 'autostart link removed' path_absent /etc/systemd/system/multi-user.target.wants/xray.service
assert_true 'owned binary removed' path_absent /usr/local/bin/xray
assert_true 'owned unit removed' path_absent /etc/systemd/system/xray.service
assert_true 'journal removed only after success' path_absent "$JOURNAL"
assert_snapshot 'original file restored after stop' "$W/original-manifest.json" /var/lib/mifa-vpn-basic/manifest
assert_snapshot 'backup unchanged' "$W/backup-before.json" /var/backups/mifa-vpn-basic
if getent passwd xray >"$W/user-after"; then user_rc=0; else user_rc=$?; fi
assert_rc 'owned account removed' 2 "$user_rc"
rollback_summary
