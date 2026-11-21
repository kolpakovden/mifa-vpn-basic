#!/usr/bin/env python3
"""Safe host tests: temporary files and a fake Docker CLI ONLY.

Run: python -B tests/test_rollback_infrastructure.py --bash /path/to/bash
Never executes install.sh, real Docker, user management or systemctl.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument("--bash", default=shutil.which("bash"))
options, remaining = parser.parse_known_args()
TESTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("probe", TESTS / "rollback_probe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
spec = importlib.util.spec_from_file_location("baseline_plan", TESTS / "baseline_plan.py")
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)
spec = importlib.util.spec_from_file_location("ci_result", TESTS / "ci_result.py")
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)

FAKE_DOCKER = r'''#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_LOG"
if [[ "${1:-}" == --host ]]; then shift 2; fi
command_name="$1"
shift
case "$command_name" in
  context)
    case "$1" in show) echo test-local ;; inspect) echo "$FAKE_ENDPOINT" ;; *) exit 90 ;; esac ;;
  info) echo linux ;;
  build)
    [[ "${FAKE_BUILD_FAIL:-0}" == 0 ]] || exit 42
    while (( $# )); do
      if [[ "$1" == --iidfile ]]; then printf 'sha256:%064d\n' 0 >"$2"; break; fi
      shift
    done ;;
  create)
    name=''
    while (( $# )); do
      if [[ "$1" == --name ]]; then name="$2"; break; fi
      shift
    done
    [[ -n "$name" ]] || exit 90
    : >"$FAKE_ROOT/containers/$name"
    echo "$name" ;;
  start)
    if [[ "${FAKE_START_RC:-0}" == 0 && "${FAKE_NO_SUMMARY:-0}" == 0 ]]; then
      case "${FAKE_TEST_RC:-0}" in
        0) printf 'rollback-regressions: пройдено 2, ошибок 0\n' ;;
        1) printf 'rollback-regressions: пройдено 1, ошибок 1\n' ;;
      esac
    fi
    exit "${FAKE_START_RC:-0}" ;;
  inspect) echo "${FAKE_TEST_RC:-0}" ;;
  ps)
    name=''
    for arg in "$@"; do
      if [[ "$arg" == name=\^/*\$ ]]; then
        name="${arg#name=^/}"
        name="${name%\$}"
      fi
    done
    [[ ! -f "$FAKE_ROOT/containers/$name" ]] || echo "$name" ;;
  rm)
    [[ "${FAKE_RM_FAIL:-0}" == 0 ]] || exit 43
    if [[ "${FAKE_RM_FAIL_ONCE:-0}" == 1 && ! -f "$FAKE_ROOT/rm-failed" ]]; then
      : >"$FAKE_ROOT/rm-failed"
      exit 43
    fi
    for name in "$@"; do
      [[ "$name" == -f ]] || rm -f -- "$FAKE_ROOT/containers/$name"
    done ;;
  *) echo "Unexpected fake docker command: $command_name" >&2; exit 90 ;;
esac
'''


class Oracles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mifa-oracle-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_snapshot_detects_content_and_type_changes(self):
        target = self.root / "file"
        target.write_bytes(b"old")
        expected = self.root / "snapshot.json"
        expected.write_text(json.dumps(probe.snapshot(target)))
        self.assertTrue(probe.check_snapshot([expected], target))
        target.write_bytes(b"new")
        self.assertFalse(probe.check_snapshot([expected], target))
        target.unlink()
        target.mkdir()
        self.assertFalse(probe.check_snapshot([expected], target))

    def test_journal_allows_append_but_rejects_truncation(self):
        before = self.root / "before"
        current = self.root / "current"
        before.write_bytes(b"remove\t/path\t\n")
        shutil.copy2(before, current)
        with current.open("ab") as stream:
            stream.write(b"completed\t/path\n")
        self.assertTrue(probe.journal_retained(before, current))
        current.write_bytes(b"completed\t/path\n")
        self.assertFalse(probe.journal_retained(before, current))

    def observer_fixture(self, state="inactive", bypass=False):
        observer = self.root / "observer"
        observer.mkdir()
        real = self.root / "real" / "rm"
        (observer / "real-tools").write_text(f"rm\t{real}\n")
        run = self.root / "run"
        run.mkdir()
        (run / "events").write_text("" if bypass else f"rm\t{state}\n")
        lines = [] if bypass else [f'execve({json.dumps(str(observer / "rm"))}, ["rm"], 0x0) = 0']
        lines.append(f'execve({json.dumps(str(real))}, ["rm"], 0x0) = 0')
        (run / "trace.123").write_text("\n".join(lines) + "\n")
        return run, observer

    def test_observer_accepts_inactive_observed_command(self):
        run, observer = self.observer_fixture()
        self.assertTrue(probe.check_observer(run, observer, ["rm"]))

    def test_observer_rejects_active_mutation(self):
        run, observer = self.observer_fixture(state="active")
        self.assertFalse(probe.check_observer(run, observer, ["rm"]))

    def test_observer_rejects_absolute_path_bypass(self):
        run, observer = self.observer_fixture(bypass=True)
        self.assertFalse(probe.check_observer(run, observer, ["rm"]))

    def test_observer_requires_expected_operations(self):
        run, observer = self.observer_fixture()
        self.assertFalse(probe.check_observer(run, observer, ["rm", "userdel"]))


class BaselinePlan(unittest.TestCase):
    catalog = planner.SMOKE + ["repeat-rmdir", "repeat-userdel"]

    def dispatch(self, **overrides):
        inputs = dict(ubuntu="24.04", scenarios="smoke", run_systemd=False, disposable_linux_vm=False)
        inputs.update(overrides)
        return planner.select("workflow_dispatch", planner.BRANCH, {"inputs": inputs}, self.catalog)

    def test_bootstrap_is_fixed_despite_spoofed_inputs(self):
        event = {"head_commit": {"message": "ci: smoke [baseline-smoke]"},
                 "inputs": {"ubuntu": "all", "scenarios": "all", "run_systemd": True,
                            "disposable_linux_vm": True}}
        result = planner.select("push", planner.BRANCH, event, self.catalog)
        self.assertEqual(result["versions"], ["24.04"])
        self.assertEqual(result["scenarios"], ["control-remove", "control-restore", "repeat-remove",
                                               "parent-chmeta", "staging-symlink", "enable-without-stop"])
        self.assertFalse(result["run_systemd"])
        self.assertEqual(result["profile"], "push-smoke")

    def test_ordinary_push_and_other_branch_cannot_select_tests(self):
        for ref, message in [(planner.BRANCH, "ordinary push"),
                             ("refs/heads/main", "[baseline-smoke]"),
                             ("refs/tags/experiment/deepseek-rollback", "[baseline-smoke]")]:
            with self.subTest(ref=ref, message=message), self.assertRaises(ValueError):
                planner.select("push", ref, {"head_commit": {"message": message}}, self.catalog)

    def test_deleted_branch_missing_head_and_pr_are_rejected(self):
        for event in [{}, {"head_commit": None},
                      {"deleted": True, "head_commit": {"message": "[baseline-smoke]"}}]:
            with self.subTest(event=event), self.assertRaises(ValueError):
                planner.select("push", planner.BRANCH, event, self.catalog)
        with self.assertRaises(ValueError):
            planner.select("pull_request", planner.BRANCH, {}, self.catalog)

    def test_manual_smoke_defaults_do_not_enable_systemd(self):
        plan = self.dispatch()
        self.assertEqual(plan["versions"], ["24.04"])
        self.assertEqual(plan["scenarios"], planner.SMOKE)
        self.assertFalse(plan["run_systemd"])

    def test_manual_explicit_version_and_cases(self):
        plan = self.dispatch(ubuntu="26.04", scenarios="control-remove, repeat-rmdir")
        self.assertEqual(plan["versions"], ["26.04"])
        self.assertEqual(plan["scenarios"], ["control-remove", "repeat-rmdir"])

    def test_all_requires_explicit_selection(self):
        plan = self.dispatch(ubuntu="all", scenarios="all")
        self.assertEqual(plan["versions"], ["22.04", "24.04", "26.04"])
        self.assertEqual(plan["scenarios"], self.catalog)

    def test_invalid_empty_duplicate_and_shell_inputs_fail_closed(self):
        for key, values in {"ubuntu": ["", "25.04", "$(whoami)"],
                            "scenarios": ["", " ", "missing", "control-remove,", "all,control-remove",
                                          "control-remove,control-remove", "$(whoami)"]}.items():
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    self.dispatch(**{key: value})

    def test_systemd_requires_both_booleans(self):
        with self.assertRaises(ValueError):
            self.dispatch(run_systemd=True)
        self.assertFalse(self.dispatch(disposable_linux_vm=True)["run_systemd"])
        self.assertTrue(self.dispatch(run_systemd="true", disposable_linux_vm="true")["run_systemd"])
        with self.assertRaises(ValueError):
            self.dispatch(run_systemd="yes", disposable_linux_vm=True)

    def test_broken_catalog_cannot_silently_drop_cases(self):
        for catalog in [[], ["control-remove"], self.catalog + ["control-remove"]]:
            with self.subTest(catalog=catalog), self.assertRaises(ValueError):
                planner.select("push", planner.BRANCH,
                               {"head_commit": {"message": "[baseline-smoke]"}}, catalog)

    def test_cli_reads_event_file_and_outputs_exact_push_matrix(self):
        with tempfile.TemporaryDirectory(prefix="mifa-plan-") as directory:
            event_path = Path(directory) / "event.json"
            event_path.write_text(json.dumps({"head_commit": {"message": "[baseline-smoke]"}}),
                                  encoding="utf-8")
            env = dict(os.environ, GITHUB_EVENT_PATH=str(event_path), GITHUB_EVENT_NAME="push",
                       GITHUB_REF=planner.BRANCH)
            result = subprocess.run([sys.executable, "-B", str(TESTS / "baseline_plan.py")],
                                    input="\n".join(self.catalog) + "\n", env=env,
                                    capture_output=True, text=True, encoding="utf-8", timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            outputs = dict(line.split("=", 1) for line in result.stdout.splitlines())
            self.assertEqual(json.loads(outputs["versions"]), ["24.04"])
            self.assertEqual(json.loads(outputs["scenarios"]), planner.SMOKE)
            self.assertEqual(outputs["run_systemd"], "false")


class ResultEvidence(unittest.TestCase):
    success = "rollback-regressions: пройдено 2, ошибок 0\n"
    failure = "rollback-regressions: пройдено 1, ошибок 1\n"

    def test_exit_one_without_summary_is_not_defect_reproduction(self):
        result = reporter.classify("rollback", "setup failed", 1, 0)
        self.assertEqual(result["classification"], "INFRASTRUCTURE_OR_INCOMPLETE")
        self.assertEqual(result["effective_exit_code"], 1)

    def test_assertion_failure_requires_summary_and_matching_exit(self):
        result = reporter.classify("rollback", self.failure, 1, 0)
        self.assertEqual(result["classification"], "TEST_ASSERTIONS_FAILED")
        self.assertEqual(result["assertions_failed"], 1)
        for console, rc in [(self.failure, 0), (self.success, 1), (self.failure, 2),
                            (self.failure + self.failure, 1)]:
            with self.subTest(rc=rc, console=console):
                result = reporter.classify("rollback", console, rc, 0)
                self.assertEqual(result["classification"], "INFRASTRUCTURE_OR_INCOMPLETE")
                self.assertNotEqual(result["effective_exit_code"], 0)

    def test_zero_without_assertions_cannot_be_a_pass(self):
        for console in ["", "rollback-regressions: пройдено 0, ошибок 0\n"]:
            result = reporter.classify("rollback", console, 0, 0)
            self.assertEqual(result["status"], "FAIL")
            self.assertEqual(result["effective_exit_code"], 2)

    def test_logging_error_is_not_a_success_or_assertion_failure(self):
        result = reporter.classify("rollback", self.success, 0, 44)
        self.assertEqual(result["classification"], "LOGGING_ERROR")
        self.assertEqual(result["effective_exit_code"], 44)
        self.assertEqual(reporter.classify("rollback", self.failure, 1, 44)["effective_exit_code"], 1)

    def test_probe_errors_override_assertions_even_if_raw_exit_is_one(self):
        for marker, classification in [("MIFA_PROBE_ERROR\t2", "PROBE_EXECUTION_ERROR"),
                                       ("MIFA_PROBE_INFRA_ERROR\t3", "INFRASTRUCTURE_ERROR")]:
            result = reporter.classify("rollback", self.failure + marker + "\n", 1, 0)
            self.assertEqual(result["classification"], classification)
            self.assertEqual(result["assertions_failed"], 1)


@unittest.skipUnless(options.bash, "Bash unavailable")
class ProbeExecution(unittest.TestCase):
    def exercise(self, fault):
        # Real probe and Bash helper, temporary fixture data only. No installer.
        with tempfile.TemporaryDirectory(prefix="mifa-probe-exit-") as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text("original", encoding="utf-8")
            expected = root / "expected.json"
            expected.write_text(json.dumps(probe.snapshot(target)), encoding="utf-8")
            if fault == "mismatch":
                target.write_text("replacement", encoding="utf-8")
            elif fault == "probe":
                expected.write_text("invalid json", encoding="utf-8")
            elif fault == "infrastructure":
                expected.unlink()
            shim = root / "python3"
            shim.write_text("#!/usr/bin/env bash\nexec " + shlex.quote(Path(sys.executable).as_posix())
                            + ' -B "$@"\n', encoding="utf-8", newline="\n")
            shim.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ.get("PATH", ""),
                       PROBE_TESTS=TESTS.as_posix(), PROBE_FILE=(TESTS / "rollback_probe.py").as_posix(),
                       EXPECTED=expected.as_posix(), TARGET=target.as_posix(),
                       MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")
            script = r'''
set -euo pipefail
T_NAME=rollback-regressions
. "$PROBE_TESTS/lib.sh"
. "$PROBE_TESTS/rollback_test_lib.sh"
RB_PROBE="$PROBE_FILE"
assert_snapshot 'fixture check' "$EXPECTED" "$TARGET"
t_pass 'independent check still runs'
rollback_summary
'''
            result = subprocess.run([options.bash, "-s"], input=script, env=env,
                                    capture_output=True, text=True, encoding="utf-8", timeout=20)
            console = result.stdout + result.stderr
            return result, reporter.classify("rollback", console, result.returncode, 0)

    def test_mismatch_is_assertion_failure(self):
        result, report = self.exercise("mismatch")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(report["classification"], "TEST_ASSERTIONS_FAILED")
        self.assertEqual(report["assertions_failed"], 1)

    def test_invalid_json_is_probe_error_and_checks_continue(self):
        result, report = self.exercise("probe")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("independent check still runs", result.stdout)
        self.assertEqual(report["classification"], "PROBE_EXECUTION_ERROR")
        self.assertEqual(report["assertions_failed"], 0)
        self.assertEqual(report["probe_exit_codes"], [2])

    def test_missing_reference_is_infrastructure_error(self):
        result, report = self.exercise("infrastructure")
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("independent check still runs", result.stdout)
        self.assertEqual(report["classification"], "INFRASTRUCTURE_ERROR")
        self.assertEqual(report["assertions_failed"], 0)

    def test_missing_journal_subject_is_mismatch(self):
        with tempfile.TemporaryDirectory(prefix="mifa-journal-probe-") as directory:
            before = Path(directory) / "before"
            before.write_text("remove\t/path\t\n", encoding="utf-8")
            self.assertFalse(probe.journal_retained(before, Path(directory) / "missing"))


@unittest.skipUnless(options.bash, "Bash unavailable")
class RunnerGuards(unittest.TestCase):
    def run_runner(self, suite, ci_capture=False, **overrides):
        with tempfile.TemporaryDirectory(prefix="mifa-runner-test-") as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "containers").mkdir()
            (root / "tmp").mkdir()
            fake = root / "bin" / "docker"
            fake.write_text(FAKE_DOCKER, encoding="utf-8", newline="\n")
            fake.chmod(0o755)
            # Use this exact interpreter even if Windows python3 is an app alias.
            python_shim = root / "bin" / "python3"
            python_shim.write_text("#!/usr/bin/env bash\nexec " + shlex.quote(Path(sys.executable).as_posix())
                                   + ' -B "$@"\n', newline="\n")
            python_shim.chmod(0o755)
            log = root / "log"
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("DOCKER_", "MIFA_", "RUNNER_"))
                   and key != "GITHUB_ACTIONS"}
            env.update(PATH=str(root / "bin") + os.pathsep + env.get("PATH", ""),
                       FAKE_ROOT=root.as_posix(), FAKE_LOG=log.as_posix(),
                       TMPDIR=(root / "tmp").as_posix(), FAKE_ENDPOINT="unix:///fake/docker.sock",
                       MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")
            env.update(overrides)
            script = "run-ci-docker.sh" if ci_capture else "run-docker.sh"
            args = [options.bash, str(TESTS / script), suite, "24.04"]
            if ci_capture:
                args.append((root / "results").as_posix())
            result = subprocess.run(args,
                                    env=env, capture_output=True, text=True, encoding="utf-8", timeout=60)
            if ci_capture:
                result.report = json.loads((root / "results/result.json").read_text(encoding="utf-8"))
                result.summary = (root / "results/summary.md").read_text(encoding="utf-8")
                result.console = (root / "results/console.log").read_text(encoding="utf-8")
            calls = log.read_text() if log.exists() else ""
            survivors = list((root / "containers").iterdir())
            return result, calls, len(survivors)

    def test_remote_context_is_rejected_before_daemon_contact(self):
        result, calls, _ = self.run_runner("rollback", FAKE_ENDPOINT="ssh://vpn.example")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Remote/unsupported", result.stderr)
        self.assertNotIn(" info ", calls)
        self.assertNotIn(" build ", calls)

    def test_remote_docker_host_is_rejected(self):
        result, calls, _ = self.run_runner("rollback", DOCKER_HOST="tcp://vpn.example:2376")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, "")

    def test_systemd_requires_explicit_confirmation(self):
        result, calls, _ = self.run_runner("rollback-systemd")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--disposable-linux-vm", result.stderr)
        self.assertNotIn(" build ", calls)

    def test_failed_build_aborts_all_without_create(self):
        result, calls, _ = self.run_runner("all", FAKE_BUILD_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no cached-image fallback", result.stderr)
        self.assertNotIn(" create ", calls)

    def test_all_never_creates_privileged_containers(self):
        result, calls, survivors = self.run_runner("all")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn(" create ", calls)
        self.assertNotIn("--privileged", calls)
        self.assertNotIn("--target systemd", calls)
        self.assertNotIn(" exec ", calls)
        self.assertEqual(survivors, 0)

    def test_failed_test_still_removes_container(self):
        result, calls, survivors = self.run_runner("guards", FAKE_TEST_RC="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(" rm -f ", calls)
        self.assertEqual(survivors, 0)

    def test_cleanup_failure_cannot_be_success(self):
        result, calls, survivors = self.run_runner("guards", FAKE_RM_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cleanup failed", result.stderr.lower())
        self.assertIn("Runner state retained", result.stderr)
        self.assertGreater(survivors, 0)

    def test_actions_self_hosted_is_rejected_before_docker(self):
        result, calls, _ = self.run_runner("rollback", GITHUB_ACTIONS="true",
                                          RUNNER_ENVIRONMENT="self-hosted", RUNNER_OS="Linux")
        self.assertEqual(result.returncode, 2)
        self.assertIn("self-hosted is forbidden", result.stderr)
        self.assertEqual(calls, "")

    def test_actions_other_unix_socket_is_rejected_before_daemon(self):
        result, calls, _ = self.run_runner("rollback", GITHUB_ACTIONS="true",
                                          RUNNER_ENVIRONMENT="github-hosted", RUNNER_OS="Linux")
        self.assertEqual(result.returncode, 2)
        self.assertIn("local default Docker socket", result.stderr)
        self.assertNotIn(" info ", calls)

    def test_actions_push_and_pr_cannot_authorize_privileged_runner(self):
        for event in ["push", "pull_request", ""]:
            with self.subTest(event=event):
                result, calls, _ = self.run_runner("rollback-systemd", GITHUB_ACTIONS="true",
                                                  RUNNER_ENVIRONMENT="github-hosted", RUNNER_OS="Linux",
                                                  GITHUB_EVENT_NAME=event)
                self.assertEqual(result.returncode, 2)
                self.assertIn("require workflow_dispatch", result.stderr)
                self.assertEqual(calls, "")

    def test_single_case_keeps_exit_status_and_uses_one_container(self):
        result, calls, survivors = self.run_runner("rollback", MIFA_ROLLBACK_CASE="repeat-remove",
                                                  FAKE_TEST_RC="37", GITHUB_ACTIONS="true",
                                                  RUNNER_ENVIRONMENT="github-hosted", RUNNER_OS="Linux",
                                                  FAKE_ENDPOINT="unix:///var/run/docker.sock")
        self.assertEqual(result.returncode, 37, result.stderr + result.stdout)
        self.assertEqual(calls.count(" create "), 1)
        self.assertIn("rollback_regressions.sh repeat-remove", calls)
        self.assertEqual(survivors, 0)

    def test_unknown_case_is_rejected_before_docker(self):
        result, calls, _ = self.run_runner("rollback", MIFA_ROLLBACK_CASE="bogus")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, "")

    def test_ci_report_does_not_hide_expected_failure(self):
        result, _, survivors = self.run_runner("rollback", ci_capture=True,
                                               MIFA_ROLLBACK_CASE="repeat-remove", FAKE_TEST_RC="1")
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        self.assertEqual(result.report["status"], "FAIL")
        self.assertEqual(result.report["expected_before_fixes"], "FAIL")
        self.assertEqual(result.report["runner_exit_code"], 1)
        self.assertEqual(result.report["classification"], "TEST_ASSERTIONS_FAILED")
        self.assertIn("**FAIL**", result.summary)
        self.assertIn("exit code: 1", result.console)
        self.assertEqual(survivors, 0)

    def test_ci_report_keeps_build_error_distinct(self):
        result, calls, _ = self.run_runner("rollback", ci_capture=True,
                                          MIFA_ROLLBACK_CASE="repeat-remove", FAKE_BUILD_FAIL="1")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.report["runner_exit_code"], 2)
        self.assertEqual(result.report["status"], "FAIL")
        self.assertEqual(result.report["classification"], "INFRASTRUCTURE_OR_INCOMPLETE")
        self.assertIn("Image build failed", result.console)
        self.assertNotIn(" create ", calls)

    def test_ci_report_keeps_timeout_distinct(self):
        result, _, survivors = self.run_runner("rollback", ci_capture=True,
                                               MIFA_ROLLBACK_CASE="repeat-remove", FAKE_START_RC="124")
        self.assertEqual(result.returncode, 124)
        self.assertEqual(result.report["runner_exit_code"], 124)
        self.assertEqual(result.report["status"], "FAIL")
        self.assertEqual(result.report["classification"], "TIMEOUT")
        self.assertEqual(survivors, 0)

    def test_ci_report_records_positive_control(self):
        result, _, _ = self.run_runner("rollback", ci_capture=True,
                                      MIFA_ROLLBACK_CASE="control-remove")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.report["expected_before_fixes"], "PASS")
        self.assertEqual(result.report["status"], "PASS")

    def test_ci_report_rejects_zero_exit_without_completion_evidence(self):
        result, _, _ = self.run_runner("rollback", ci_capture=True,
                                      MIFA_ROLLBACK_CASE="control-remove", FAKE_NO_SUMMARY="1")
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertEqual(result.report["runner_exit_code"], 0)
        self.assertEqual(result.report["classification"], "INFRASTRUCTURE_OR_INCOMPLETE")

    def test_ci_retains_both_test_and_cleanup_failures(self):
        result, _, survivors = self.run_runner("rollback", ci_capture=True,
                                               MIFA_ROLLBACK_CASE="repeat-remove",
                                               FAKE_TEST_RC="1", FAKE_RM_FAIL="1")
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        self.assertEqual(result.report["test_exit_code"], 1)
        self.assertEqual(result.report["runner_exit_code"], 1)
        self.assertEqual(result.report["classification"], "CLEANUP_ERROR")
        self.assertEqual(result.report["test_classification"], "TEST_ASSERTIONS_FAILED")
        self.assertEqual(result.report["cleanup_errors"], [{"phase": "remove", "exit_code": 43},
                                                          {"phase": "exit-remove", "exit_code": 43}])
        self.assertIn('"exit_code": 43', result.summary)
        self.assertGreater(survivors, 0)

    def test_ci_cleanup_error_after_success_is_not_green(self):
        result, _, _ = self.run_runner("rollback", ci_capture=True,
                                      MIFA_ROLLBACK_CASE="control-remove", FAKE_RM_FAIL="1")
        self.assertEqual(result.returncode, 43, result.stderr + result.stdout)
        self.assertEqual(result.report["test_exit_code"], 0)
        self.assertEqual(result.report["test_classification"], "PASS")
        self.assertEqual(result.report["status"], "FAIL")
        self.assertEqual(result.report["classification"], "CLEANUP_ERROR")

    def test_cleanup_retry_does_not_erase_original_errors(self):
        result, _, survivors = self.run_runner("rollback", ci_capture=True,
                                               MIFA_ROLLBACK_CASE="repeat-remove",
                                               FAKE_TEST_RC="37", FAKE_RM_FAIL_ONCE="1")
        self.assertEqual(result.returncode, 37, result.stderr + result.stdout)
        self.assertEqual(result.report["test_exit_code"], 37)
        self.assertEqual(result.report["cleanup_errors"], [{"phase": "remove", "exit_code": 43}])
        self.assertEqual(survivors, 0)


if __name__ == "__main__":
    unittest.main(argv=[__file__] + remaining)
