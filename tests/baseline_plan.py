#!/usr/bin/env python3
"""Read-only baseline selection. Never executes Docker or the installer."""
import json
import os
from pathlib import Path
import re
import sys

BRANCH = "refs/heads/experiment/deepseek-rollback"
SMOKE = ["control-remove", "control-restore", "repeat-remove", "parent-chmeta",
         "staging-symlink", "enable-without-stop"]
VERSIONS = ["22.04", "24.04", "26.04"]
P14_CONTROLS = ["control-remove", "control-restore", "staging-file", "staging-symlink",
                "staging-directory", "destination-directory"]
P14_NEGATIVE = ["repeat-remove", "parent-chmeta", "enable-without-stop"]


def boolean(value):
    if value is True or value == "true":
        return True
    if value is False or value == "false":
        return False
    raise ValueError("Expected an explicit boolean")


def select(event_name, ref, event, catalog, push_profile="smoke"):
    if not catalog or len(catalog) != len(set(catalog)):
        raise ValueError("Empty or duplicate regression catalog")
    if not all(re.fullmatch(r"[a-z][a-z0-9-]*", name) for name in catalog):
        raise ValueError("Invalid regression catalog")
    if event_name == "push":
        message = (event.get("head_commit") or {}).get("message", "")
        if ref != BRANCH or event.get("deleted") or "[baseline-smoke]" not in message:
            raise ValueError("Push requires the exact experimental branch and HEAD opt-in marker")
        # Bootstrap AND dispatch-unavailable fallback: fixed, unprivileged only.
        # Do not use dispatch inputs or commit text as matrix values on push.
        versions, cases, systemd, profile = ["24.04"], SMOKE[:], False, "push-smoke"
        if push_profile == "p14":
            restores = [name for name in catalog if name.startswith("restore-")]
            if not restores:
                raise ValueError("P1-4 restore regression catalog is empty")
            cases, profile = P14_CONTROLS + restores + P14_NEGATIVE, "push-p14"
        elif push_profile != "smoke":
            raise ValueError("Unknown push baseline profile")
    elif event_name == "workflow_dispatch":
        inputs = event.get("inputs") or {}
        version = inputs.get("ubuntu", "")
        if version not in VERSIONS + ["all"]:
            raise ValueError("Select Ubuntu 22.04, 24.04, 26.04 or all")
        versions = VERSIONS[:] if version == "all" else [version]
        requested = inputs.get("scenarios", "").strip()
        if requested == "smoke":
            cases = SMOKE[:]
        elif requested == "all":
            cases = catalog[:]
        else:
            cases = [part.strip() for part in requested.split(",")]
        systemd = boolean(inputs.get("run_systemd", False))
        confirmed = boolean(inputs.get("disposable_linux_vm", False))
        if systemd and not confirmed:
            raise ValueError("Real systemd requires explicit disposable Linux VM confirmation")
        profile = "dispatch"
    else:
        raise ValueError("Unsupported event; no tests authorized")
    if not cases or len(cases) != len(set(cases)) or any(case not in catalog for case in cases):
        raise ValueError("Empty, duplicate or unknown scenario selection")
    return {"versions": versions, "scenarios": cases, "run_systemd": systemd, "profile": profile}


def main():
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        plan = select(os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"],
                      event, sys.stdin.read().splitlines(),
                      os.environ.get("MIFA_BASELINE_PUSH_PROFILE", "smoke"))
    except (ValueError, KeyError, OSError) as error:
        print(f"Baseline selection refused: {error}", file=sys.stderr)
        return 2
    # Caller appends stdout to GITHUB_OUTPUT. Values are validated/JSON encoded.
    for key, value in plan.items():
        print(f"{key}={json.dumps(value) if not isinstance(value, str) else value}")
    print("Baseline plan: " + json.dumps(plan), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
