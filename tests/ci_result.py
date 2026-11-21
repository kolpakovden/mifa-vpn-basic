#!/usr/bin/env python3
"""Classify console evidence; an assertion failure is NOT automatic proof of a P1."""
import json
import os
from pathlib import Path
import re
import sys


def classify(suite, console, runner_rc, log_rc):
    test_results = re.findall(r"^MIFA_RUNNER_TEST_EXIT\t([^\t\r\n]+)\t(\d+)\r?$", console, re.MULTILINE)
    test_rc = int(test_results[0][1]) if len(test_results) == 1 else None
    cleanup_errors = [{"phase": phase, "exit_code": int(code)} for phase, code in
                      re.findall(r"^MIFA_RUNNER_CLEANUP_ERROR\t([^\t\r\n]+)\t(\d+)\r?$", console, re.MULTILINE)]
    probe_errors = [int(code) for code in re.findall(r"^MIFA_PROBE_ERROR\t(\d+)\r?$", console, re.MULTILINE)]
    probe_infra_errors = [int(code) for code in re.findall(r"^MIFA_PROBE_INFRA_ERROR\t(\d+)\r?$", console, re.MULTILINE)]
    name = "rollback-regressions" if suite == "rollback" else suite
    summaries = re.findall(rf"^{re.escape(name)}: пройдено (\d+), ошибок (\d+)\r?$",
                           console, re.MULTILINE)
    counts = tuple(map(int, summaries[0])) if len(summaries) == 1 else None
    completed = counts is not None and sum(counts) > 0
    effective_rc = runner_rc or log_rc
    # Test evidence and cleanup evidence remain independent, including when both fail.
    evidence_rc = test_rc if test_rc is not None else runner_rc
    if probe_infra_errors:
        classification = "INFRASTRUCTURE_ERROR"
    elif probe_errors:
        classification = "PROBE_EXECUTION_ERROR"
    elif evidence_rc == 124:
        classification = "TIMEOUT"
    elif evidence_rc >= 128:
        classification = "TERMINATED"
    elif completed and counts[1] == 0 and evidence_rc == 0:
        classification = "PASS"
    elif completed and counts[1] > 0 and evidence_rc == 1:
        classification = "TEST_ASSERTIONS_FAILED"
    else:
        classification = "INFRASTRUCTURE_OR_INCOMPLETE"
        # Exit 0 without test completion is not a verified pass. Retain raw 0
        # in JSON, but fail the reporting wrapper explicitly.
    test_classification = classification
    if cleanup_errors:
        classification = "CLEANUP_ERROR"
    if log_rc:
        classification = "LOGGING_ERROR"
    if classification != "PASS":
        effective_rc = effective_rc or 2
    if effective_rc and classification == "PASS":
        classification = "INFRASTRUCTURE_OR_INCOMPLETE"
    return {"classification": classification, "effective_exit_code": effective_rc,
            "test_classification": test_classification, "test_exit_code": test_rc,
            "cleanup_errors": cleanup_errors, "probe_exit_codes": probe_errors,
            "probe_infrastructure_exit_codes": probe_infra_errors,
            "status": "PASS" if effective_rc == 0 else "FAIL",
            "summary_completed": completed,
            "assertions_passed": counts[0] if counts else None,
            "assertions_failed": counts[1] if counts else None}


def main():
    suite, ubuntu, scenario, directory, raw_rc, raw_log_rc = sys.argv[1:]
    output = Path(directory)
    runner_rc, log_rc = int(raw_rc), int(raw_log_rc)
    console = (output / "console.log").read_text(encoding="utf-8", errors="replace")
    report = classify(suite, console, runner_rc, log_rc)
    expected = "PASS" if scenario in ("control-remove", "control-restore", "e2e") else "FAIL"
    report.update(ubuntu=ubuntu, scenario=scenario, expected_before_fixes=expected,
                  runner_exit_code=runner_rc, log_exit_code=log_rc,
                  commit_sha=os.environ.get("GITHUB_SHA", ""),
                  ref=os.environ.get("GITHUB_REF", ""), event=os.environ.get("GITHUB_EVENT_NAME", ""),
                  profile=os.environ.get("MIFA_BASELINE_PROFILE", ""))
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    sha = report["commit_sha"]
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", sha):
        sha = "unavailable"
    summary = (
        "| Ubuntu | Scenario | Expected before fixes | Actual | Classification | Runner exit | Log exit |\n"
        "| --- | --- | --- | --- | --- | --- | --- |\n"
        f"| {ubuntu} | {scenario} | {expected} | **{report['status']}** | "
        f"{report['classification']} | {runner_rc} | {log_rc} |\n\n"
        f"Commit: `{sha}`. Reporting exit: {report['effective_exit_code']}.\n\n"
        f"Original test exit: {report['test_exit_code']}; test classification: {report['test_classification']}.\n\n"
        f"Cleanup failures (all attempts): `{json.dumps(report['cleanup_errors'])}`.\n\n"
        f"Probe execution errors: {report['probe_exit_codes']}; probe infrastructure errors: {report['probe_infrastructure_exit_codes']}.\n\n"
        "Expected FAIL is a hypothesis. TEST_ASSERTIONS_FAILED means assertions completed with failures; "
        "inspect individual assertions before claiming defect reproduction. Infrastructure errors, "
        "missing/contradictory summaries and timeouts are not reproduced defects.\n"
    )
    (output / "summary.md").write_text(summary, encoding="utf-8")
    print(summary)
    return report["effective_exit_code"]


if __name__ == "__main__":
    sys.exit(main())
