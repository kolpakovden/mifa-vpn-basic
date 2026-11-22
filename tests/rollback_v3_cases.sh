# shellcheck shell=bash
# Case bodies for rollback_regressions.sh. Never runnable as a host test.
[[ "${MIFA_TEST_DISPOSABLE:-0}" == 1 && -f /.dockerenv && "$EUID" == 0 && "${W:-}" == /tmp/* ]] || exit 2

v3_setup() {
  if [[ "$kind" == chmeta ]]; then install -d -m 0700 "$XRAY_CONF_DIR"; fi
  txn_begin
}
v3_apply() {
  case "$kind" in
    remove) txn_install_file "$W/source" "$XRAY_BIN" 0755 root root ;;
    rmdir|chmeta) txn_mkdir "$XRAY_CONF_DIR" 0750 root root ;;
    userdel) txn_create_user ;;
  esac
}
v3_target_snapshot() {
  if [[ "$kind" == userdel ]]; then
    for db in passwd shadow group gshadow; do save_snapshot "/etc/$db" "$W/target-$db.json"; done
  else
    save_snapshot "$target" "$W/target.json"
  fi
}
v3_target_unchanged() {
  if [[ "$kind" == userdel ]]; then
    for db in passwd shadow group gshadow; do assert_snapshot "$db preserved" "$W/target-$db.json" "/etc/$db"; done
  else
    assert_snapshot 'target and its metadata preserved' "$W/target.json" "$target"
  fi
}
v3_outcome() {
  case "$kind" in
    remove|rmdir) assert_true 'owned object absent after successful first undo' path_absent "$target" ;;
    chmeta) assert_eq 'original directory metadata restored' '700:0:0' "$(metadata "$target")" ;;
    userdel)
      if getent passwd xray >/dev/null; then account_rc=0; else account_rc=$?; fi
      assert_rc 'owned account absent' 2 "$account_rc"
      if getent group xray >/dev/null; then group_rc=0; else group_rc=$?; fi
      assert_rc 'owned private group absent' 2 "$group_rc"
      ;;
  esac
}
v3_faults() {
  cat >"$W/v3-faults" <<'FAULTS'
printf() {
  if [[ "${1:-}" == '%s\t%s\t%s\n' && "${2:-}-write" == "$MIFA_V3_FAILURE" ]]; then
    builtin printf 'MIFA_V3_INJECTED\t%s\n' "$MIFA_V3_FAILURE" >&2
    return 42
  fi
  builtin printf "$@"
}
sync() {
  if [[ "${1:-}" == /var/lib/mifa-vpn-basic/journal.inprogress && "$MIFA_V3_FAILURE" == *-sync ]]; then
    local last
    last="$(tail -n 1 "$1")"
    if [[ "$last" == "${MIFA_V3_FAILURE%-sync}"$'\t'* ]]; then
      builtin printf 'MIFA_V3_INJECTED\t%s\n' "$MIFA_V3_FAILURE"
      return 42
    fi
  fi
  command sync "$@"
}
FAULTS
}

if [[ "$CASE" == v3-v2-restore-control ]]; then
  prepare_restore
  printf '%s\nrestore\t%s\t%s\n' "$JOURNAL_V2_HEADER" "$MANIFEST" "$BACKUP_PATH" >"$JOURNAL"
  rollback
  assert_rc 'legacy v2 restore-only journal still works' 0 "$RB_RC"
  assert_snapshot 'v2 original restored independently' "$W/original-manifest.json" "$MANIFEST"
  assert_snapshot 'v2 backup preserved' "$W/backup-before.json" "$BACKUP_DIR"
  assert_true 'v2 journal removed only on complete restoration' path_absent "$JOURNAL"
elif [[ "$CASE" == v3-legacy-* ]]; then
  suffix="${CASE#v3-legacy-v}"; version="${suffix%%-*}"; kind="${suffix#*-}"
  v3_setup
  v3_apply
  target="$XRAY_CONF_DIR"
  [[ "$kind" != remove ]] || target="$XRAY_BIN"
  [[ "$kind" != userdel ]] || target=xray
  {
    [[ "$version" != 2 ]] || printf '%s\n' "$JOURNAL_V2_HEADER"
    printf '%s\t%s\t%s\n' "$kind" "$target" "$([[ "$kind" != chmeta ]] || echo 700:0:0)"
  } >"$W/legacy-journal"
  cat "$W/legacy-journal" >"$JOURNAL"
  v3_target_snapshot
  rollback
  incomplete
  v3_target_unchanged
  assert_true 'legacy journal not amended or upgraded' cmp -s "$W/legacy-journal" "$JOURNAL"
else
  suffix="${CASE#v3-}"; kind="${suffix%%-*}"; event="${suffix#*-}"
  target="$XRAY_CONF_DIR"
  [[ "$kind" != remove ]] || target="$XRAY_BIN"
  [[ "$kind" != userdel ]] || target=xray
  v3_setup
  case "$event" in
    existing-group)
      must test "$kind" = userdel
      groupadd --gid 22222 xray
      v3_target_snapshot
      if v3_apply; then setup_rc=0; else setup_rc=$?; fi
      assert_rc_nonzero 'pre-existing group rejects user creation' "$setup_rc"
      v3_target_unchanged
      rollback
      assert_rc 'no unowned user/group undo was journaled' 0 "$RB_RC"
      v3_target_unchanged
      ;;
    prepare-kill|ready-kill|group-kill|created-kill|prepare-write|prepare-sync|ready-write|ready-sync)
      # A separate shell creates only this fixture's transaction objects.
      # No EXIT rollback trap is installed: model a real incomplete setup.
      v3_faults
      if [[ "$event" == *-kill ]]; then
        fault=v3_after_prepare
        [[ "$event" != ready-kill ]] || fault=v3_before_ready
        [[ "$event" != group-kill ]] || fault=v3_userdel_group_created
        [[ "$event" != created-kill ]] || fault=v3_created_without_generation
        export -f v3_apply
        export W kind
        if MIFA_BASIC_TEST_MODE=1 MIFA_BASIC_TEST_FAIL_AT="$fault:kill" bash -c '
          MIFA_BASIC_LIB=1 . "$INSTALL_SH"
          set +e +E
          trap - EXIT ERR
          v3_apply
        ' >"$W/setup.out" 2>&1; then setup_rc=0; else setup_rc=$?; fi
        cat "$W/setup.out"
        assert_rc 'setup process interrupted' 137 "$setup_rc"
        if [[ "$event" == created-kill ]]; then
          must grep -Fxq "$(printf 'MIFA_V3_KILL\t%s' "$fault")" "$W/setup.out"
          untagged="$(python3 - "$JOURNAL" <<'PY'
import json, sys
records = [line.rstrip('\n').split('\t') for line in open(sys.argv[1])]
print(json.loads([r[2] for r in records if r[0] == 'prepare'][-1])['path'])
PY
)"
          must test -e "$untagged"
          assert_true 'generation was not attached before SIGKILL' python3 -c \
            'import os,sys; sys.exit(any(k.startswith("user.mifa.rollback.") for k in os.listxattr(sys.argv[1])))' "$untagged"
          save_snapshot "$untagged" "$W/untagged.json"
        else
          must grep -Fq "Тестовый SIGKILL на шаге $fault" "$W/setup.out"
        fi
      else
        export MIFA_V3_FAILURE="$event"
        export -f v3_apply
        export W kind
        if bash -c '
          MIFA_BASIC_LIB=1 . "$INSTALL_SH"
          set +e +E
          trap - EXIT ERR
          . "$W/v3-faults"
          v3_apply
        ' >"$W/setup.out" 2>&1; then setup_rc=0; else setup_rc=$?; fi
        cat "$W/setup.out"
        assert_rc_nonzero 'setup append/flush failure propagated' "$setup_rc"
        must grep -Fxq "$(printf 'MIFA_V3_INJECTED\t%s' "$event")" "$W/setup.out"
      fi
      # Own file publication hasn't happened at either prepare/ready hook.
      # rmdir/chmeta/userdel ready failures leave a real object but no ready.
      v3_target_snapshot
      rollback
      if [[ "$event" == ready-sync ]]; then
        # The complete ready line was visible, with a fully synced witness.
        # The next durable undoing flush also flushes ready before any mutation.
        assert_rc 'visible ready is revalidated and flushed before undo' 0 "$RB_RC"
        v3_outcome
      elif [[ "$event" == prepare-write || ( "$kind" != chmeta && ( "$event" == prepare-kill || "$event" == prepare-sync ) ) ]]; then
        assert_rc 'no installation mutation: safe cancellation' 0 "$RB_RC"
        v3_target_unchanged
      else
        incomplete
        v3_target_unchanged
      fi
      if [[ "$event" == created-kill ]]; then
        assert_snapshot 'created but untagged object retained' "$W/untagged.json" "$untagged"
      fi
      ;;
    *)
      v3_apply
      case "$event" in
        control)
          rollback
          assert_rc 'first v3 rollback succeeds' 0 "$RB_RC"
          v3_outcome
          assert_true 'journal removed only on success' path_absent "$JOURNAL"
          ;;
        before|after|after-replaced|before-done|partial)
          hook="v3_${kind}_${event//-/_}"
          [[ "$event" != after-replaced ]] || hook="v3_${kind}_after"
          MIFA_BASIC_TEST_MODE=1 MIFA_BASIC_TEST_FAIL_AT="$hook:kill" observed_rollback
          assert_rc 'undo process interrupted by SIGKILL' 137 "$RB_RC"
          must grep -q $'^undoing\t' "$JOURNAL"
          assert_journal_retained
          # Partial chown hook runs in Python, other hooks in the CLI.
          if [[ "$event" == partial ]]; then
            must grep -Fxq "$(printf 'MIFA_V3_KILL\t%s' "$hook")" "$W/rollback.out"
          else
            must grep -Fq "Тестовый SIGKILL на шаге $hook" "$W/rollback.out"
          fi
          if [[ "$event" == after-replaced ]]; then
            case "$kind" in
              remove) printf 'administrator new file\n' >"$target" ;;
              rmdir) install -d -m 0711 "$target" ;;
              chmeta) chmod 0711 "$target" ;;
              userdel) useradd --uid 22222 --no-create-home --shell /usr/sbin/nologin xray ;;
            esac
          fi
          v3_target_snapshot
          rollback
          if [[ "$event" == before || "$event" == partial || "$event" == after-replaced ]]; then incomplete; else assert_rc 'verify-only retry confirms result' 0 "$RB_RC"; fi
          v3_target_unchanged
          ;;
        intent-write|intent-sync|done-write|done-sync)
          v3_faults
          failure="${event/intent-/undoing-}"; failure="${failure/done-/undone-}"
          v3_target_snapshot
          MIFA_V3_FAILURE="$failure" BASH_ENV="$W/v3-faults" observed_rollback
          must grep -Fxq "$(printf 'MIFA_V3_INJECTED\t%s' "$failure")" "$W/rollback.out"
          incomplete
          if [[ "$event" == intent-* ]]; then v3_target_unchanged; else v3_outcome; fi
          v3_target_snapshot
          rollback
          if [[ "$event" == intent-sync ]]; then
            incomplete
            v3_target_unchanged
          else
            assert_rc 'safe completion or still-unissued intent on retry' 0 "$RB_RC"
            v3_outcome
          fi
          ;;
        replaced|copied-generation)
          if [[ "$kind" == userdel ]]; then
            uid="$(id -u xray)"; gid="$(id -g xray)"
            gecos="$(getent passwd xray | cut -d: -f5)"
            userdel xray
            if ! getent group "$gid" >/dev/null; then groupadd --gid "$gid" xray; fi
            # Deliberate UID reuse, plus copying GECOS in the stronger case.
            [[ "$event" == copied-generation ]] || gecos=Administrator
            useradd --uid "$uid" --gid "$gid" --no-user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --comment "$gecos" xray
            # A copied generation alone is not a supported malicious-root threat;
            # change supplementary membership to make the account ambiguous.
            groupadd mifa-admin-test
            usermod -aG mifa-admin-test xray
          else
            # Keep the original inode allocated, forcing a different identity.
            mv -T -- "$target" "$W/original-owned"
            cp -a -- "$W/original-owned" "$target"
            must test "$(stat -c '%i' "$target")" != "$(stat -c '%i' "$W/original-owned")"
            if [[ "$event" == replaced ]]; then
              python3 - "$target" <<'PY'
import os, sys
for key in os.listxattr(sys.argv[1]):
    if key.startswith('user.mifa.rollback.'):
        os.removexattr(sys.argv[1], key)
PY
            fi
          fi
          v3_target_snapshot
          rollback
          incomplete
          v3_target_unchanged
          ;;
        *) echo "Unknown v3 event: $event" >&2; exit 2 ;;
      esac
      ;;
  esac
fi
