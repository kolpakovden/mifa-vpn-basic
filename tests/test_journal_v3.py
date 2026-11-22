#!/usr/bin/env python3
"""Host-safe protocol tests. Only temporary journals are real filesystem writes.

The embedded production parser/checker is executed with simulated descriptors,
xattrs and account databases. These tests do NOT establish Linux syscall or
SIGKILL correctness; those cases live in rollback_regressions.sh containers.
"""
import argparse
import copy
import errno
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

parser = argparse.ArgumentParser()
parser.add_argument("--bash", default=shutil.which("bash"))
options, remaining = parser.parse_known_args()
ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / "install.sh").read_text(encoding="utf-8")
BODY = SOURCE.split("<<'V3PY'\n", 1)[1].split("\nV3PY", 1)[0]
CHECKER = {}
exec(compile(BODY.split("\ntry:\n    main()", 1)[0], "install.sh:V3PY", "exec"), CHECKER)
HEADER = CHECKER["HEADER"] + "\nstate\t/var/lib/mifa-vpn-basic\tcreated\n"
ID = "1" * 32
PATH = "/usr/local/bin/xray"
EVIDENCE = dict(dev=1, ino=42, uid=0, gid=0, mode=0o755, attrs={},
                size=7, mtime_ns=12345, sha256="a" * 64)


def specification(kind="remove"):
    result = dict(kind=kind, path=PATH, token=ID, before=None, target=None, group_created=False)
    if kind in ("rmdir", "chmeta"):
        result["path"] = "/usr/local/etc/xray"
    if kind == "chmeta":
        result["before"] = directory()
        result["before"]["mode"] = 0o700
        result["target"] = dict(mode=0o750, uid=0, gid=0)
    if kind == "userdel":
        result.update(path="xray", group_created=True)
    return result


def directory():
    return {k: v for k, v in EVIDENCE.items() if k not in ("size", "mtime_ns", "sha256")}


def witness(kind):
    if kind == "userdel":
        return dict(passwd=f"xray:x:999:999:Xray (MIFA VPN Basic tx={ID}):/nonexistent:/usr/sbin/nologin",
                    shadow_sha256="b" * 64, groups_sha256="c" * 64, subids_sha256="d" * 64)
    result = copy.deepcopy(EVIDENCE if kind == "remove" else directory())
    if kind == "chmeta":
        result["mode"] = 0o750
    return result


def line(action, arg="", key=ID):
    return f"{action}\t{key}\t{json.dumps(arg, separators=(',', ':')) if isinstance(arg, dict) else arg}\n"


def journal(kind="remove", phase="ready"):
    data = HEADER + line("prepare", specification(kind))
    if phase == "prepared":
        return data
    if phase == "cancelled":
        return data + line("cancelled")
    data += line("ready", witness(kind))
    if phase in ("undoing", "undone"):
        data += line("undoing")
    if phase == "undone":
        data += line("undone")
    return data


class Protocol(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mifa-v3-safe-")
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "journal"

    def validate(self, data):
        self.path.write_bytes(data.encode())
        return CHECKER["validate"](str(self.path))

    def test_all_valid_states_and_kinds(self):
        for kind in CHECKER["KINDS"]:
            for phase in ("prepared", "ready", "undoing", "undone", "cancelled"):
                with self.subTest(kind=kind, phase=phase):
                    ops, normalized = self.validate(journal(kind, phase))
                    self.assertEqual(ops[ID]["phase"], phase)
                    self.assertIn("owned-" + kind, normalized[1])

    def test_malformed_and_reordered_protocol(self):
        base = journal()
        cases = [base[:-1], base.replace("v3", "v2"), base.replace("state\t", "unknown\t"),
                 base + line("ready", EVIDENCE), base + line("prepare", specification(), "2" * 32),
                 HEADER + line("undoing"), journal(phase="prepared") + line("undone"),
                 base + line("undone"), base + line("undoing") * 2,
                 base + line("undoing", key="2" * 32), base + line("undoing", "unexpected"),
                 base + line("undoing") + line("prepare", specification(), "2" * 32),
                 base + "remove\t/usr/local/bin/xray\t\n", base.replace('"ino":42', '"ino":42,"ino":43'),
                 base.replace('"token":"' + ID, '"token":"oops'),
                 base.replace('"mode":493', '"mode":true'),
                 HEADER + line("prepare", specification()) + line("ready", {}),
                 base + "restore\t/usr/local/bin/xray\t/backup\n"]
        for data in cases:
            with self.subTest(data=data):
                with self.assertRaises(CHECKER["Refuse"]):
                    self.validate(data)

    def test_chmeta_ready_must_match_preparation(self):
        data = journal("chmeta")
        for wrong in (dict(witness("chmeta"), ino=43), dict(witness("chmeta"), mode=0o777)):
            with self.assertRaises(CHECKER["Refuse"]):
                self.validate(data.replace(line("ready", witness("chmeta")), line("ready", wrong)))

    def run_fs(self, cmd, kind="remove", phase="ready", current=None, token=ID, missing=False,
               fail_chmod=False):
        self.validate(journal(kind, phase))
        current = copy.deepcopy(witness(kind) if current is None else current)
        calls = []
        fake_open = lambda *a, **kw: 101
        if missing:
            def fake_open(*a, **kw):
                raise FileNotFoundError(errno.ENOENT, "absent")
        fake_os = types.SimpleNamespace(**vars(os))
        fake_os.environ = {}
        def forbidden_kill(*a):
            raise AssertionError("Host-safe tests must never signal a real process")
        fake_os.kill = forbidden_kill
        # Values are only passed to fake_open; no Windows syscall uses them.
        fake_os.O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0x20000)
        fake_os.O_NONBLOCK = getattr(os, "O_NONBLOCK", 0x800)
        fake_os.open = fake_open
        fake_os.close = lambda fd: None
        fake_os.getxattr = lambda *a: token.encode()
        fake_os.stat = lambda *a, **kw: types.SimpleNamespace(st_dev=current["dev"], st_ino=current["ino"],
                                                             st_mode=(0o100000 if kind == "remove" else 0o040000) | current["mode"])
        fake_os.unlink = lambda *a, **kw: calls.append("unlink")
        fake_os.rmdir = lambda *a, **kw: calls.append("rmdir")
        fake_os.fchown = lambda *a: calls.append("fchown")
        def chmod(*a):
            calls.append("fchmod")
            if fail_chmod:
                raise OSError(errno.EIO, "injected partial chmeta")
        fake_os.fchmod = chmod
        fake_os.fsync = lambda fd: calls.append("fsync")
        with patch.dict(CHECKER, os=fake_os, parents=lambda path: (100, "object"),
                        snapshot=lambda *a: current), patch.object(sys, "argv", ["helper", cmd, str(self.path), ID]):
            try:
                CHECKER["main"]()
            except (CHECKER["Refuse"], OSError, SystemExit):
                return False, calls
        return True, calls

    def test_delete_requires_generation_and_full_ready_witness(self):
        for kind in ("remove", "rmdir"):
            self.assertEqual(self.run_fs("mutate", kind, "undoing")[1][:1], ["unlink" if kind == "remove" else "rmdir"])
            # Same inode+attributes without generation is insufficient.
            ok, calls = self.run_fs("mutate", kind, "undoing", token="2" * 32)
            self.assertFalse(ok)
            self.assertEqual(calls, [])
            # Copying even the generation marker onto a new inode is insufficient.
            ok, calls = self.run_fs("mutate", kind, "undoing", current=dict(witness(kind), ino=999))
            self.assertFalse(ok)
            self.assertEqual(calls, [])

    def test_prepared_object_cannot_be_undone(self):
        for kind in ("remove", "rmdir", "chmeta"):
            self.assertEqual(self.run_fs("check", kind, "prepared"), (False, []))
            self.assertEqual(self.run_fs("absent", kind, "prepared"), (False, []))
        self.assertEqual(self.run_fs("absent", phase="prepared", missing=True), (True, []))

    def test_mutation_requires_durable_intent(self):
        self.assertEqual(self.run_fs("mutate"), (False, []))

    def test_verify_only_after_delete_rejects_replacement(self):
        for phase in ("undoing", "undone"):
            self.assertEqual(self.run_fs("outcome", phase=phase), (False, []))
            self.assertEqual(self.run_fs("outcome", phase=phase, missing=True), (True, []))

    def test_chmeta_partial_execution_is_not_repeated(self):
        ok, calls = self.run_fs("mutate", "chmeta", "undoing", fail_chmod=True)
        self.assertFalse(ok)
        self.assertEqual(calls, ["fchown", "fchmod"])
        self.assertEqual(self.run_fs("outcome", "chmeta", "undoing"), (False, []))
        before = specification("chmeta")["before"]
        self.assertEqual(self.run_fs("outcome", "chmeta", "undoing", current=before), (True, []))
        self.assertEqual(self.run_fs("outcome", "chmeta", "undone", current=dict(before, mode=0o711)), (False, []))

    def test_reused_inode_without_generation_is_not_ownership(self):
        # Deterministic inode-reuse model: identical dev/ino, bytes and metadata;
        # actual kernel inode allocation is deliberately not assumed by tests.
        for kind in ("remove", "rmdir", "chmeta"):
            self.assertEqual(self.run_fs("check", kind, token=""), (False, []))

    def test_account_generation_uid_reuse_and_independent_changes(self):
        spec = specification("userdel")
        passwd = witness("userdel")["passwd"]
        databases = {"/etc/passwd": passwd + "\n", "/etc/shadow": "xray:!:1:0:99999:7:::\n",
                     "/etc/group": "xray:x:999:\n", "/etc/gshadow": f"xray:!mifa-tx-{ID}::\n"}
        def getpwnam(name):
            if not databases["/etc/passwd"]: raise KeyError(name)
            return ("xray", "x", 999, 999, passwd.split(":")[4], "/nonexistent", "/usr/sbin/nologin")
        def getgrnam(name):
            if not databases["/etc/group"]: raise KeyError(name)
            return types.SimpleNamespace(gr_name="xray", gr_gid=999)
        fake_pwd = types.SimpleNamespace(getpwnam=getpwnam)
        fake_grp = types.SimpleNamespace(getgrgid=lambda gid: types.SimpleNamespace(gr_name="xray"), getgrnam=getgrnam)
        fake_os = types.SimpleNamespace(**vars(os))
        fake_os.lstat = lambda path: types.SimpleNamespace(st_mode=0o100600, st_uid=0)
        fake_os.path = types.SimpleNamespace(lexists=lambda path: path in databases)
        def reader(path, *a, **kw):
            return io.StringIO(databases[path])
        with patch.dict(sys.modules, pwd=fake_pwd, grp=fake_grp), patch.dict(CHECKER, os=fake_os), patch("builtins.open", reader):
            original = CHECKER["account"](spec)
            databases["/etc/subuid"] = "xray:100000:65536\n"
            with self.assertRaises(CHECKER["Refuse"]):
                CHECKER["account"](spec)
            del databases["/etc/subuid"]
            # Same UID, new account generation: refuse, even if names match.
            databases["/etc/passwd"] = passwd.replace(ID, "2" * 32) + "\n"
            with self.assertRaises(CHECKER["Refuse"]):
                CHECKER["account"](spec)
            databases["/etc/passwd"] = passwd + "\n"
            databases["/etc/shadow"] = "xray:!:2:0:99999:7:::\n"
            self.assertNotEqual(CHECKER["account"](spec), original)
            databases["/etc/gshadow"] = "xray:!::\n"
            with self.assertRaises(CHECKER["Refuse"]):
                CHECKER["account"](spec)  # same GID is not the same group generation
            databases["/etc/gshadow"] = f"xray:!mifa-tx-{ID}::\n"
            databases["/etc/passwd"] = ""
            with self.assertRaises(CHECKER["Refuse"]):
                CHECKER["account"](spec)  # orphan/new private group is ambiguous
            databases["/etc/group"] = ""
            with self.assertRaises(CHECKER["Refuse"]):
                CHECKER["account"](spec)  # orphan shadow/gshadow is not completion
            databases["/etc/shadow"] = databases["/etc/gshadow"] = ""
            self.assertIsNone(CHECKER["account"](spec))
            databases["/etc/subuid"] = "999:100000:65536\n"
            with self.assertRaises(CHECKER["Refuse"]):
                CHECKER["account"](spec, original)
            del databases["/etc/subuid"]
            fake_pwd.getpwnam = lambda name: ("xray", "x", 999, 999, "remote", "/", "/bin/sh")
            with self.assertRaises(CHECKER["Refuse"]):
                CHECKER["account"](spec)


@unittest.skipUnless(options.bash, "Bash unavailable")
class DurableOrdering(unittest.TestCase):
    def test_container_fault_wrappers_are_exercised_without_system_calls(self):
        source = (ROOT / "tests/rollback_v3_cases.sh").read_text(encoding="utf-8")
        wrappers = source.split("<<'FAULTS'\n", 1)[1].split("\nFAULTS", 1)[0]
        for action in ("prepare", "ready", "undoing", "undone"):
            for failure in ("write", "sync"):
                env = os.environ.copy()
                env.update(MIFA_V3_FAILURE=action + "-" + failure, ACTION=action,
                           MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")
                command = 'printf \'%s\\t%s\\t%s\\n\' "$ACTION" id argument' if failure == "write" else 'sync /var/lib/mifa-vpn-basic/journal.inprogress'
                script = wrappers + r'''
command() { echo UNEXPECTED_SYSTEM_CALL >&2; return 99; }
tail() { builtin printf '%s\tid\targument\n' "$ACTION"; }
''' + command + "\nexit $?\n"
                result = subprocess.run([options.bash, "-s"], input=script, env=env, capture_output=True,
                                        text=True, encoding="utf-8", timeout=20)
                self.assertEqual(result.returncode, 42)
                self.assertNotIn("UNEXPECTED_SYSTEM_CALL", result.stdout + result.stderr)
                self.assertIn("MIFA_V3_INJECTED\t" + action + "-" + failure, result.stdout + result.stderr)

    def run_case(self, phase="ready", failure="", kind="remove"):
        with tempfile.TemporaryDirectory(prefix="mifa-v3-order-") as directory:
            fixture = Path(directory) / "journal"
            fixture.write_text("", encoding="utf-8")
            env = {k: v for k, v in os.environ.items() if not k.startswith("MIFA_")}
            env.update(INSTALL_LIB=(ROOT / "install.sh").as_posix(), FIXTURE=fixture.as_posix(),
                       PHASE=phase, FAILURE=failure, KIND=kind, MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")
            script = r'''
MIFA_BASIC_LIB=1
. "$INSTALL_LIB"
set +e +E
trap - ERR EXIT
txn_restore_parents_safe() { return 0; }
txn_v3_python() {
  case "$1" in
    status) builtin printf '%s\t%s\tobject\n' "$PHASE" "$KIND" ;;
    absent)
      if [[ "$FAILURE" == absent-infra ]]; then echo INFRASTRUCTURE_ERROR >>"$FIXTURE"; return 2; fi
      return 1 ;;
    check|outcome) echo "$1" >>"$FIXTURE" ;;
    mutate) echo MUTATE >>"$FIXTURE" ;;
    *) exit 99 ;;
  esac
}
userdel() { echo MUTATE >>"$FIXTURE"; }
sync() {
  if [[ "$FAILURE" == *sync && "$(tail -1 "$FIXTURE")" == "${FAILURE%-sync}"$'\t'* ]]; then return 42; fi
  echo SYNC >>"$FIXTURE"
}
printf() {
  if [[ "$FAILURE" == "${2:-}-write" ]]; then return 42; fi
  builtin printf "$@"
}
txn_v3_undo "$FIXTURE" 11111111111111111111111111111111
exit $?
'''
            result = subprocess.run([options.bash, "-s"], input=script, env=env, capture_output=True,
                                    text=True, encoding="utf-8", timeout=20)
            return result.returncode, fixture.read_text(encoding="utf-8").splitlines()

    def test_intent_must_be_written_and_synced_before_mutation(self):
        for kind in ("remove", "rmdir", "chmeta", "userdel"):
            with self.subTest(kind=kind):
                rc, events = self.run_case(kind=kind)
                self.assertEqual(rc, 0)
                intent = next(i for i, e in enumerate(events) if e.startswith("undoing\t"))
                mutation = events.index("MUTATE")
                done = next(i for i, e in enumerate(events) if e.startswith("undone\t"))
                self.assertLess(intent, events.index("SYNC"))
                self.assertLess(events.index("SYNC"), mutation)
                self.assertLess(mutation, events.index("outcome"))
                self.assertLess(events.index("outcome"), done)

    def test_intent_failure_forbids_mutation(self):
        for failure in ("undoing-write", "undoing-sync"):
            rc, events = self.run_case(failure=failure)
            self.assertNotEqual(rc, 0)
            self.assertNotIn("MUTATE", events)
            self.assertFalse(any(e.startswith("undone\t") for e in events))

    def test_absence_check_io_error_forbids_mutation(self):
        rc, events = self.run_case(failure="absent-infra")
        self.assertNotEqual(rc, 0)
        self.assertEqual(events, ["INFRASTRUCTURE_ERROR"])

    def test_completion_failure_is_reported_after_mutation(self):
        for failure in ("undone-write", "undone-sync"):
            rc, events = self.run_case(failure=failure)
            self.assertNotEqual(rc, 0)
            self.assertEqual(events.count("MUTATE"), 1)

    def test_replay_never_mutates(self):
        for phase in ("prepared", "cancelled", "undoing", "undone"):
            rc, events = self.run_case(phase=phase)
            self.assertNotIn("MUTATE", events)
            self.assertEqual(rc, 1 if phase in ("prepared", "cancelled") else 0)


@unittest.skipUnless(options.bash, "Bash unavailable")
class ServicePhase(unittest.TestCase):
    def exercise(self, owned="1", fail_stop="0"):
        # Redirect only the unit constant to an owned temp file. All systemd,
        # receipt verification and undo actions are stubs; never host services.
        with tempfile.TemporaryDirectory(prefix="mifa-service-order-") as directory:
            root = Path(directory)
            unit, fixture, log, state = [root / n for n in ("unit", "journal", "events", "active")]
            unit.write_text("owned fixture")
            fixture.write_text("fixture")
            log.write_text("")
            state.write_text("active\n")
            library = root / "installer.sh"
            library.write_text(SOURCE.replace('readonly XRAY_UNIT="/etc/systemd/system/xray.service"',
                                               'readonly XRAY_UNIT="$FIXTURE_UNIT"'), encoding="utf-8", newline="\n")
            env = {k: v for k, v in os.environ.items() if not k.startswith("MIFA_")}
            env.update(INSTALL_LIB=library.as_posix(), FIXTURE_UNIT=unit.as_posix(), FIXTURE=fixture.as_posix(),
                       EVENTS=log.as_posix(), ACTIVE=state.as_posix(), OWNED=owned, FAIL_STOP=fail_stop,
                       MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")
            script = r'''
MIFA_BASIC_LIB=1
. "$INSTALL_LIB"
set +e +E
trap - ERR EXIT
txn_restore_parents_safe() { return 0; }
journal_validate() {
  RB_JOURNAL_VERSION=3
  RB_JOURNAL_ENTRIES=("$(printf 'owned-remove\t%s\tid' "$XRAY_UNIT")" $'owned-remove\t/usr/local/bin/xray\tbinary')
}
txn_systemd_available() { return 0; }
txn_v3_python() { echo CHECK >>"$EVENTS"; [[ "$1" == check && "$OWNED" == 1 ]]; }
txn_v3_undo() { echo FILES >>"$EVENTS"; }
systemctl() {
  case "$1" in
    show)
      case "$*" in
        *LoadState*) echo loaded ;;
        *FragmentPath*) echo "$XRAY_UNIT" ;;
        *DropInPaths*) echo '' ;;
        *) return 99 ;;
      esac ;;
    stop) echo STOP >>"$EVENTS"; [[ "$FAIL_STOP" == 0 ]] || return 1; echo inactive >"$ACTIVE" ;;
    is-active) cat "$ACTIVE" ;;
    disable) echo DISABLE >>"$EVENTS" ;;
    daemon-reload) echo RELOAD >>"$EVENTS" ;;
    reset-failed) echo RESET >>"$EVENTS" ;;
    *) return 99 ;;
  esac
}
txn_disable_unit() { systemctl disable xray.service; }
txn_rollback "$FIXTURE"
exit $?
'''
            result = subprocess.run([options.bash, "-s"], input=script, env=env, capture_output=True,
                                    text=True, encoding="utf-8", timeout=20)
            return result.returncode, log.read_text().splitlines(), fixture.exists()

    def test_owned_service_stops_before_every_file_action(self):
        rc, events, retained = self.exercise()
        self.assertEqual(rc, 0)
        self.assertEqual(events, ["CHECK", "STOP", "DISABLE", "FILES", "FILES", "RELOAD", "RESET"])
        self.assertFalse(retained)

    def test_foreign_service_receipt_cannot_authorize_any_mutation(self):
        self.assertEqual(self.exercise(owned="0"), (3, ["CHECK"], True))

    def test_failed_stop_blocks_disable_and_files(self):
        self.assertEqual(self.exercise(fail_stop="1"), (3, ["CHECK", "STOP"], True))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *remaining])
