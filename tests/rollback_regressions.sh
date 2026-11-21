#!/usr/bin/env bash
# Destructive regression tests: one CASE per fresh disposable Linux container.
# Run: bash tests/run-docker.sh rollback 24.04
# No Xray download, network target or real systemd is needed. Filesystem and
# account operations are REAL; only systemctl is modelled. Never run on a host.
# A passing bash -n is NOT a runtime test result.
set -Eeuo pipefail
T_NAME="rollback-regressions"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/rollback_test_lib.sh
. "${TESTS_DIR}/rollback_test_lib.sh"

CASES=(control-remove control-restore repeat-remove repeat-rmdir repeat-chmeta
       repeat-userdel parent-remove parent-rmdir parent-chmeta leaf-chmeta
       setup-symlink-chmeta parent-restore backup-parent-restore
       staging-file staging-symlink staging-directory destination-directory
       enable-without-stop)

# Listing does not source install.sh or perform any filesystem/account mutation.
if [[ "${1:-}" == --list ]]; then
  printf '%s\n' "${CASES[@]}"
  exit 0
fi
CASE="${1:-}"
case " ${CASES[*]} " in
  *" ${CASE} "*) [[ -n "$CASE" ]] || exit 2 ;;
  *) echo "Unknown case: ${CASE}; use --list" >&2; exit 2 ;;
esac
require_disposable
[[ "$(uname -s)" == Linux ]] || { echo 'Linux container required' >&2; exit 2; }
[[ -f /.dockerenv ]] || { echo 'Docker container marker required' >&2; exit 2; }

MIFA_BASIC_LIB=1
# shellcheck source=install.sh
. "$INSTALL_SH"
set -Eeuo pipefail

# Refuse dirty containers instead of cleaning anything that could be foreign.
for p in "$XRAY_BIN" "$XRAY_CONF_DIR" "$XRAY_UNIT" "$STATE_DIR" "$BACKUP_ROOT"; do
  if [[ -e "$p" || -L "$p" ]]; then
    echo "Fresh container required: ${p} exists" >&2
    exit 2
  fi
done
if getent passwd xray >/dev/null || getent group xray >/dev/null; then
  echo 'Fresh container required: xray account/group exists' >&2
  exit 2
fi

W="$(mktemp -d)"
# Deliberately no recursive cleanup: the runner removes the owned container.
printf 'inactive\n' >"$W/active"
printf 'disabled\n' >"$W/enabled"
: >"$W/events"
printf 'transaction payload\n' >"$W/source"

# Model systemd availability ONLY inside the guarded disposable plain container.
# Rollback itself runs through the real CLI in a separate traced bash process.
mkdir -p /run/systemd/system "$W/mock"
export MIFA_RB_TEST_DIR="$W"
cat >"$W/mock/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
W="$MIFA_RB_TEST_DIR"
  printf 'systemctl %s\n' "$*" >>"$W/events"
  case "$1" in
    stop) printf 'inactive\n' >"$W/active" ;;
    disable) printf 'disabled\n' >"$W/enabled" ;;
    is-active)
      cat "$W/active"
      [[ "$(cat "$W/active")" == active ]]
      ;;
    show)
      case "$*" in
        *ActiveState*) cat "$W/active" ;;
        *UnitFileState*) cat "$W/enabled" ;;
        *LoadState*) printf 'loaded\n' ;;
        *) exit 2 ;;
      esac
      ;;
    daemon-reload|reset-failed) exit 0 ;;
    *) echo "Unexpected systemctl call: $*" >&2; exit 2 ;;
  esac
MOCK
chmod 0755 "$W/mock/systemctl"
export PATH="$W/mock:$PATH"
RB_OBSERVER_SYSTEMCTL="$W/mock/systemctl"
make_observer

must() {
  if ! "$@"; then
    printf 'SETUP FAILED [%s]: %s\n' "$CASE" "$*" >&2
    [[ ! -f "$W/rollback.out" ]] || cat "$W/rollback.out" >&2
    exit 2
  fi
}
rollback() {
  observed_rollback
}
incomplete() {
  assert_rc "$CASE: ambiguous state returns 3" 3 "$RB_RC"
  assert_journal_retained
}
metadata() { stat -c '%a:%u:%g' -- "$1"; }
tree() { find "$1" -mindepth 1 -printf '%P|%y|%m|%u|%g|%l\n' | sort; }
prepare_restore() {
  # A pre-existing state file is explicitly supported by existing E2E tests.
  install -d -m 0700 "$STATE_DIR"
  printf 'original manifest\n' >"$MANIFEST"
  chmod 0600 "$MANIFEST"
  save_snapshot "$MANIFEST" "$W/original-manifest.json"
  txn_begin
  txn_install_file "$W/source" "$MANIFEST" 0600 root root
  save_snapshot "$MANIFEST" "$W/destination-before.json"
  save_snapshot "$BACKUP_DIR" "$W/backup-before.json"
}

t_section "$CASE"
case "$CASE" in
  control-remove)
    txn_begin
    txn_install_file "$W/source" "$XRAY_BIN" 0755 root root
    rollback
    assert_rc 'normal owned file rollback succeeds' 0 "$RB_RC"
    assert_true 'owned file removed, including symlinks' path_absent "$XRAY_BIN"
    assert_true 'journal removed' path_absent "$JOURNAL"
    ;;
  control-restore)
    prepare_restore
    rollback
    assert_rc 'normal restore succeeds' 0 "$RB_RC"
    assert_snapshot 'original type, bytes and metadata restored' "$W/original-manifest.json" "$MANIFEST"
    assert_snapshot 'backup unchanged' "$W/backup-before.json" "$BACKUP_DIR"
    assert_true 'journal removed' path_absent "$JOURNAL"
    ;;
  repeat-*)
    if [[ "$CASE" == repeat-chmeta ]]; then
      install -d -m 0700 "$XRAY_CONF_DIR"
    fi
    txn_begin
    case "$CASE" in
      repeat-remove) txn_install_file "$W/source" "$XRAY_BIN" 0755 root root ;;
      repeat-rmdir|repeat-chmeta) txn_mkdir "$XRAY_CONF_DIR" 0750 root root ;;
      repeat-userdel) txn_create_user ;;
    esac
    # A real rmdir conflict retains the journal after other undo actions succeed.
    printf 'keep\n' >"$STATE_DIR/keep-me.txt"
    rollback
    must test "$RB_RC" = 3
    must test -f "$JOURNAL"
    case "$CASE" in
      repeat-remove)
        must path_absent "$XRAY_BIN"
        printf 'administrator replacement\n' >"$XRAY_BIN"
        save_snapshot "$XRAY_BIN" "$W/expected.json"
        ;;
      repeat-rmdir)
        must path_absent "$XRAY_CONF_DIR"
        install -d -m 0711 "$XRAY_CONF_DIR"
        ;;
      repeat-chmeta)
        must test "$(metadata "$XRAY_CONF_DIR")" = '700:0:0'
        chmod 0711 "$XRAY_CONF_DIR"
        ;;
      repeat-userdel)
        if getent passwd xray >/dev/null; then echo 'Initial userdel failed' >&2; exit 2; fi
        useradd --uid 22222 --no-create-home --shell /usr/sbin/nologin xray
        getent passwd xray >"$W/expected-user"
        ;;
    esac
    # The second attempt must fail BECAUSE of the replacement/edited object,
    # not because of the unrelated blocker used to keep the first journal.
    command rm -- "$STATE_DIR/keep-me.txt"
    must path_absent "$STATE_DIR/keep-me.txt"
    case "$CASE" in
      repeat-rmdir|repeat-chmeta) save_snapshot "$XRAY_CONF_DIR" "$W/expected.json" ;;
      repeat-userdel)
        for account_file in passwd shadow group gshadow; do
          save_snapshot "/etc/$account_file" "$W/$account_file.json"
        done
        ;;
    esac
    rollback
    incomplete
    case "$CASE" in
      repeat-remove) assert_snapshot 'new file preserved' "$W/expected.json" "$XRAY_BIN" ;;
      repeat-rmdir|repeat-chmeta)
        assert_snapshot 'administrator directory and metadata preserved' "$W/expected.json" "$XRAY_CONF_DIR"
        ;;
      repeat-userdel)
        assert_eq 'replacement account preserved' "$(cat "$W/expected-user")" "$(getent passwd xray || true)"
        for account_file in passwd shadow group gshadow; do
          assert_snapshot "account database $account_file preserved" "$W/$account_file.json" "/etc/$account_file"
        done
        ;;
    esac
    ;;
  parent-remove|parent-rmdir|parent-chmeta|leaf-chmeta|parent-restore)
    install -d -m 0700 "$XRAY_CONF_DIR" "$W/outside"
    case "$CASE" in
      parent-chmeta) install -d -m 0700 "$XRAY_CONF_DIR/child" ;;
      parent-restore) printf 'old config\n' >"$XRAY_CONF" ;;
    esac
    txn_begin
    case "$CASE" in
      parent-remove|parent-restore) txn_install_file "$W/source" "$XRAY_CONF" 0640 root root ;;
      parent-rmdir|parent-chmeta) txn_mkdir "$XRAY_CONF_DIR/child" 0750 root root ;;
      leaf-chmeta) txn_mkdir "$XRAY_CONF_DIR" 0750 root root ;;
    esac
    mv -T -- "$XRAY_CONF_DIR" "$W/owned-directory"
    printf 'foreign data\n' >"$W/outside/config.json"
    install -d -m 0711 "$W/outside/child"
    chmod 0711 "$W/outside"
    cp -a -- "$W/outside" "$W/expected-outside"
    before_tree="$(tree "$W/outside")"
    before_meta="$(metadata "$W/outside")"
    save_snapshot "$W/outside" "$W/outside-before.json"
    ln -s -- "$W/outside" "$XRAY_CONF_DIR"
    rollback
    incomplete
    assert_true 'outside bytes preserved' cmp -s "$W/expected-outside/config.json" "$W/outside/config.json"
    assert_eq 'outside entries and metadata preserved' "$before_tree" "$(tree "$W/outside")"
    assert_eq 'outside directory metadata preserved' "$before_meta" "$(metadata "$W/outside")"
    assert_true 'replacement link preserved' test -L "$XRAY_CONF_DIR"
    assert_snapshot 'entire outside tree preserved' "$W/outside-before.json" "$W/outside"
    ;;
  setup-symlink-chmeta)
    install -d -m 0700 /usr/local/etc "$W/outside"
    ln -s -- "$W/outside" "$XRAY_CONF_DIR"
    txn_begin
    if ( txn_mkdir "$XRAY_CONF_DIR" 0750 root root ); then setup_rc=0; else setup_rc=$?; fi
    assert_rc_nonzero 'txn_mkdir rejects symlink before changing metadata' "$setup_rc"
    assert_eq 'target permissions untouched' '700:0:0' "$(metadata "$W/outside")"
    ;;
  backup-parent-restore)
    prepare_restore
    backup_parent="$(dirname "$BACKUP_PATH")"
    mv -T -- "$backup_parent" "$W/real-backup"
    install -d -m 0700 "$W/outside"
    printf 'foreign backup\n' >"$W/outside/manifest"
    ln -s -- "$W/outside" "$backup_parent"
    save_snapshot "$MANIFEST" "$W/installed-before.json"
    save_snapshot "$W/outside" "$W/outside-before.json"
    save_snapshot "$W/real-backup" "$W/real-backup.json"
    rollback
    incomplete
    assert_true 'untrusted backup not installed' cmp -s "$W/source" "$MANIFEST"
    assert_eq 'outside source untouched' 'foreign backup' "$(cat "$W/outside/manifest")"
    assert_snapshot 'destination preserved' "$W/installed-before.json" "$MANIFEST"
    assert_snapshot 'outside source metadata preserved' "$W/outside-before.json" "$W/outside"
    assert_snapshot 'original backup preserved' "$W/real-backup.json" "$W/real-backup"
    ;;
  staging-file|staging-symlink|staging-directory)
    prepare_restore
    staging="${MANIFEST}.mifa-restore"
    printf 'foreign staging data\n' >"$W/foreign"
    case "$CASE" in
      staging-file) cp -a -- "$W/foreign" "$staging" ;;
      staging-symlink) ln -s -- "$W/foreign" "$staging" ;;
      staging-directory)
        mkdir -- "$staging"
        cp -a -- "$W/foreign" "$staging/keep"
        ;;
    esac
    save_snapshot "$staging" "$W/staging-before.json"
    save_snapshot "$W/foreign" "$W/foreign-before.json"
    rollback
    # Either use a new exclusive staging object, or refuse and retain the journal.
    # Success is only legitimate if the original destination was really restored.
    if (( RB_RC == 0 )); then
      assert_snapshot 'successful restore verified at exact destination' "$W/original-manifest.json" "$MANIFEST"
      assert_true 'journal removed only on complete success' path_absent "$JOURNAL"
    else
      incomplete
      # A failed marker write may follow a completed restore. Both known full
      # images are safe; disappearance, partial bytes or altered metadata are not.
      assert_snapshot 'destination is an intact known image after failure' \
        "$W/destination-before.json" "$W/original-manifest.json" "$MANIFEST"
    fi
    assert_snapshot 'backup preserved on success AND failure' "$W/backup-before.json" "$BACKUP_DIR"
    assert_snapshot 'staging object preserved on success AND failure' "$W/staging-before.json" "$staging"
    assert_snapshot 'foreign target type, bytes and metadata preserved' "$W/foreign-before.json" "$W/foreign"
    ;;
  destination-directory)
    prepare_restore
    mv -T -- "$MANIFEST" "$W/installed-manifest"
    mkdir -- "$MANIFEST"
    printf 'foreign data\n' >"$MANIFEST/keep"
    before_tree="$(tree "$MANIFEST")"
    save_snapshot "$MANIFEST" "$W/destination-directory.json"
    save_snapshot "${MANIFEST}.mifa-restore" "$W/staging-before.json"
    rollback
    incomplete
    assert_true 'destination remains a directory' test -d "$MANIFEST"
    assert_eq 'no file moved inside destination directory' "$before_tree" "$(tree "$MANIFEST")"
    assert_eq 'foreign content preserved' 'foreign data' "$(cat "$MANIFEST/keep")"
    assert_snapshot 'destination directory unchanged' "$W/destination-directory.json" "$MANIFEST"
    assert_snapshot 'backup unchanged' "$W/backup-before.json" "$BACKUP_DIR"
    assert_snapshot 'no staging residue' "$W/staging-before.json" "${MANIFEST}.mifa-restore"
    if grep -q $'restored\t/var/lib/mifa-vpn-basic/manifest\t' "$JOURNAL"; then marker_rc=0; else marker_rc=$?; fi
    assert_rc 'no false marker; journal must be readable' 1 "$marker_rc"
    ;;
  enable-without-stop)
    install -d -m 0700 "$XRAY_CONF_DIR"
    prepare_restore
    txn_create_user
    txn_mkdir "$XRAY_CONF_DIR" 0750 root root
    txn_mkdir "$XRAY_CONF_DIR/child" 0750 root root
    txn_install_file "$W/source" "$XRAY_CONF" 0640 root root
    txn_install_file "$W/source" "$XRAY_BIN" 0755 root root
    render_unit >"$W/xray.service"
    txn_install_file "$W/xray.service" "$XRAY_UNIT" 0644 root root
    journal_undo disable "$XRAY_SERVICE"
    # Model SIGKILL after enable, followed by boot activation. There is no stop
    # entry; disable MUST NOT change the simulated ActiveState.
    printf 'enabled\n' >"$W/enabled"
    printf 'active\n' >"$W/active"
    must test -f "$XRAY_BIN"
    if grep -q $'^stop\t' "$JOURNAL"; then echo 'Unexpected stop record' >&2; exit 2; fi
    rollback
    assert_rc 'rollback after boot activation succeeds' 0 "$RB_RC"
    assert_observed rm rmdir chmod chown cp mv userdel
    assert_eq 'service stopped' inactive "$(cat "$W/active")"
    assert_eq 'service disabled' disabled "$(cat "$W/enabled")"
    assert_true 'stop was requested' grep -qx 'systemctl stop xray.service' "$W/events"
    assert_true 'owned binary removed after stop' path_absent "$XRAY_BIN"
    assert_snapshot 'restore completed after stop' "$W/original-manifest.json" "$MANIFEST"
    assert_snapshot 'backup unchanged' "$W/backup-before.json" "$BACKUP_DIR"
    if getent passwd xray >"$W/user-after"; then user_rc=0; else user_rc=$?; fi
    assert_rc 'owned account removed after stop' 2 "$user_rc"
    ;;
esac
rollback_summary
