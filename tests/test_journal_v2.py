#!/usr/bin/env python3
"""Safe host tests: parse journals and inject function failures in temp dirs.

Sources install.sh in library mode. Never runs real rollback filesystem actions,
users, systemd or Docker. Linux restore integration remains container-only.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument("--bash", default=shutil.which("bash"))
options, remaining = parser.parse_known_args()
ROOT = Path(__file__).resolve().parent.parent
HEADER = "# MIFA VPN Basic journal v2\n"
DEST = "/var/lib/mifa-vpn-basic/manifest"
BACKUP = "/var/backups/mifa-vpn-basic/install-1" + DEST


def record(action, dest=DEST, arg=BACKUP):
    return f"{action}\t{dest}\t{arg}\n"


@unittest.skipUnless(options.bash, "Bash unavailable")
class JournalV2(unittest.TestCase):
    def execute(self, journal, script, extra=None):
        with tempfile.TemporaryDirectory(prefix="mifa-journal-v2-") as directory:
            fixture = Path(directory) / "journal"
            fixture.write_bytes(journal.encode("utf-8"))
            env = {k: v for k, v in os.environ.items() if not k.startswith("MIFA_")}
            env.update(INSTALL_LIB=(ROOT / "install.sh").as_posix(),
                       FIXTURE=fixture.as_posix(), MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")
            env.update(extra or {})
            code = '''
MIFA_BASIC_LIB=1
. "$INSTALL_LIB"
set +e +E
trap - ERR EXIT
# Temp-journal unit fixtures are outside production's trusted root paths.
# Parent traversal itself is exercised by disposable Linux regressions.
txn_restore_parents_safe() { return 0; }
# Defense in depth: refuse every system mutator if a validation test regresses.
systemctl() { echo UNEXPECTED_MUTATION >&2; return 99; }
userdel() { echo UNEXPECTED_MUTATION >&2; return 99; }
rm() { echo UNEXPECTED_MUTATION >&2; return 99; }
chmod() { echo UNEXPECTED_MUTATION >&2; return 99; }
chown() { echo UNEXPECTED_MUTATION >&2; return 99; }
cp() { echo UNEXPECTED_MUTATION >&2; return 99; }
mv() { echo UNEXPECTED_MUTATION >&2; return 99; }
rmdir() { echo UNEXPECTED_MUTATION >&2; return 99; }
''' + script
            result = subprocess.run([options.bash, "-s"], input=code, env=env, capture_output=True,
                                    text=True, encoding="utf-8", timeout=20)
            self.assertNotIn("UNEXPECTED_MUTATION", result.stderr)
            result.journal = fixture.read_text(encoding="utf-8")
            return result

    def validate(self, data):
        return self.execute(data, 'journal_validate "$FIXTURE"; exit $?\n')

    def test_v2_pending_restoring_and_completed(self):
        base = HEADER + record("restore")
        for data in [base, base + record("restoring"), base + record("restoring") + record("restored")]:
            with self.subTest(data=data):
                self.assertEqual(self.validate(data).returncode, 0)

    def test_v1_is_never_v2_and_unmarked_restore_fails_closed(self):
        for data in [record("restore"), "# old installer journal\n" + record("restore")]:
            with self.subTest(data=data):
                result = self.execute(data, 'txn_rollback "$FIXTURE"; exit $?\n')
                self.assertEqual(result.returncode, 3)
                self.assertEqual(result.journal, data)
        self.assertEqual(self.validate(record("restore") + record("restored")).returncode, 0)
        result = self.execute("", 'journal_validate "$FIXTURE"; echo "$RB_JOURNAL_VERSION"\n')
        self.assertEqual(result.stdout.strip(), "1")

    def test_legacy_undo_names_are_not_ownership_evidence(self):
        for header in ("", HEADER):
            for action, target, arg in [("remove", "/usr/local/bin/xray", ""),
                                        ("rmdir", "/usr/local/etc/xray", ""),
                                        ("chmeta", "/usr/local/etc/xray", "700:0:0"),
                                        ("userdel", "xray", "")]:
                with self.subTest(version=header, action=action):
                    data = header + record(action, target, arg)
                    result = self.execute(data, 'txn_rollback "$FIXTURE"; exit $?\n')
                    self.assertEqual(result.returncode, 3)
                    self.assertEqual(result.journal, data)

    def test_invalid_sequence_never_reaches_mutators(self):
        base = HEADER + record("restore")
        bad = [
            base + record("restored"), base + record("restoring") * 2,
            base + record("restoring") + record("restored") * 2,
            HEADER + record("restoring") + record("restore"),
            base + record("restoring", arg=BACKUP.replace("install-1", "install-2")),
            base + record("restore"),
            base + record("restoring") + record("remove", "/usr/local/bin/xray", ""),
            record("restore") + record("restoring"),
            HEADER + record("restore", arg=BACKUP + "-wrong"),
            HEADER + record("restore", arg="/var/backups/mifa-vpn-basic/install-1/nested" + DEST),
            base + record("remove", DEST, ""),
            HEADER + record("remove", DEST, "") + record("restore"),
        ]
        for data in bad:
            with self.subTest(data=data):
                result = self.execute(data, 'txn_rollback "$FIXTURE"; exit $?\n')
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertEqual(result.journal, data)

    def test_malformed_version_fields_and_truncation(self):
        base = HEADER + record("restore")
        bad = [HEADER.replace("v2", "v3") + record("restore"),
               "# comment\n" + base, HEADER + HEADER,
               base.rstrip("\n"), base + "restoring\t" + DEST + "\t",
               base + record("restoring").replace("\n", "\tgarbage\n"),
               base.replace("restore\t", "restore\t\t"),
               base.replace("restore\t", "restore\x00\t"),
               base.replace("\n", "\r\n")]
        for data in bad:
            with self.subTest(data=data):
                self.assertNotEqual(self.validate(data).returncode, 0)

    def test_marker_failure_blocks_replacement_and_retains_journal(self):
        for failure in ["write", "sync"]:
            # Real formatter+append; fake printf only for its record write.
            # Path/type helpers are stubs, so the function cannot touch a host
            # installation, and any accidental cp/mv above fails the test.
            result = self.execute(HEADER + record("restore"), '''
RB_JOURNAL_VERSION=2
txn_restore_parents_safe() { return 0; }
txn_restore_types_safe() { return 0; }
python3() { return 0; }
command() { if [[ "${1:-}" == -v && "${2:-}" == python3 ]]; then return 0; fi; builtin command "$@"; }
printf() {
  if [[ "$FAILURE" == write && "${2:-}" == restoring ]]; then echo WRITE_INJECTED >&2; return 1; fi
  builtin printf "$@"
}
sync() { if [[ "$FAILURE" == sync ]]; then echo SYNC_INJECTED; return 42; fi; }
dest="$(cd "$(dirname "$FIXTURE")" && pwd -P)/destination"
txn_restore_file "$FIXTURE" "$dest" "$dest.backup" pending
exit $?
''', {"FAILURE": failure})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(failure.upper() + "_INJECTED", result.stdout + result.stderr)
            if failure == "sync":
                self.assertIn("restoring\t", result.journal)
            self.assertNotIn("restored\t", result.journal)

    def test_journal_undo_propagates_flush_error(self):
        # JOURNAL is readonly, so exercise its exact callee on a temp journal.
        result = self.execute(HEADER, '''
sync() { return 42; }
journal_append "$FIXTURE" restoring /var/file /var/backup
exit $?
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restoring\t", result.journal)
        result = self.execute(HEADER, '''
journal_append() { return 42; }
journal_undo restore /var/file /var/backup
exit $?
''')
        self.assertEqual(result.returncode, 42)

    def test_embedded_verifier_python_compiles(self):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")
        body = source.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        compile(body, "restore-verifier", "exec")

    def test_restoring_retry_is_verify_only(self):
        for matches in [False, True]:
            result = self.execute(HEADER + record("restore") + record("restoring"), '''
RB_JOURNAL_VERSION=2
txn_restore_parents_safe() { return 0; }
txn_restore_types_safe() { return 0; }
txn_restore_matches() { echo VERIFY_CALLED >&2; [[ "$MATCHES" == yes ]]; }
sync() { return 0; }
dest="$(cd "$(dirname "$FIXTURE")" && pwd -P)/destination"
txn_restore_file "$FIXTURE" "$dest" "$dest.backup" restoring
exit $?
''', {"MATCHES": "yes" if matches else "no"})
            self.assertIn("VERIFY_CALLED", result.stderr)
            self.assertEqual(result.returncode, 0 if matches else 1, result.stderr)
            self.assertEqual("restored\t" in result.journal, matches)

    def test_verifier_error_is_distinct_from_mismatch(self):
        for raw_rc in [0, 1, 2, 127]:
            result = self.execute(HEADER, '''
python3() { return "$VERIFIER_RC"; }
txn_restore_matches "$FIXTURE" "$FIXTURE"
exit $?
''', {"VERIFIER_RC": str(raw_rc)})
            self.assertEqual(result.returncode, raw_rc if raw_rc < 2 else 2)
            self.assertEqual("MIFA_RESTORE_VERIFIER_ERROR" in result.stderr, raw_rc > 1)

    def test_fault_wrappers_prove_actual_injection_without_mutating_files(self):
        source = (ROOT / "tests/rollback_regressions.sh").read_text(encoding="utf-8")
        wrappers = source.split("<<'FAULTS'\n", 1)[1].split("\nFAULTS\n", 1)[0]
        commands = {
            "intent-write": "printf '%s\\t%s\\t%s\\n' restoring /dest /backup",
            "complete-write": "printf '%s\\t%s\\t%s\\n' restored /dest /backup",
            "intent-sync": "sync /var/lib/mifa-vpn-basic/journal.inprogress 2>/dev/null",
            "complete-sync": "sync /var/lib/mifa-vpn-basic/journal.inprogress 2>/dev/null",
            "copy": "cp -a -- /nonexistent /nonexistent/payload",
            "replace": "mv -fT -- /nonexistent/payload /nonexistent/dest",
            "false-success": "mv -fT -- /nonexistent/payload /nonexistent/dest",
        }
        for mode, command in commands.items():
            code = wrappers + '''
command() { echo UNEXPECTED_FALLBACK >&2; return 99; }
tail() { builtin printf '%s\\t/dest\\t/backup\\n' "$SYNC_PHASE"; }
''' + command + "\nexit $?\n"
            result = self.execute(HEADER, code, {"MIFA_RB_RESTORE_FAIL": mode,
                                                 "SYNC_PHASE": "restored" if mode == "complete-sync" else "restoring"})
            self.assertNotIn("UNEXPECTED_FALLBACK", result.stderr)
            self.assertIn("MIFA_RB_INJECTED\t" + mode, result.stdout + result.stderr)
            self.assertEqual(result.returncode, 0 if mode == "false-success" else 1)

    def test_restore_sigkill_cannot_leave_child_continuing(self):
        # Only owned Bash test processes; no system users, services or file ops.
        for point in ["restore_before_replace", "restore_after_replace"]:
            result = self.execute(HEADER, '''
MIFA_BASIC_TEST_MODE=1
MIFA_BASIC_TEST_FAIL_AT="$POINT:kill"
( test_fault "$POINT"; echo UNEXPECTED_CONTINUATION )
echo UNEXPECTED_PARENT_CONTINUATION
''', {"POINT": point})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Тестовый SIGKILL на шаге " + point, result.stderr)
            self.assertNotIn("UNEXPECTED_CONTINUATION", result.stdout)
            self.assertNotIn("UNEXPECTED_PARENT_CONTINUATION", result.stdout)


if __name__ == "__main__":
    unittest.main(argv=[__file__] + remaining)
