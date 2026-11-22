#!/usr/bin/env python3
"""Independent oracles: 0 pass, 1 mismatch, 2 probe error, 3 infrastructure.

Never imports installer implementation.
"""
import ast
import collections
import decimal
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys


class ProbeInfrastructureError(RuntimeError):
    pass


def snapshot(path):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return {"type": "absent"}
    result = {"mode": stat.S_IMODE(st.st_mode), "uid": st.st_uid,
              "gid": st.st_gid, "mtime_ns": st.st_mtime_ns}
    if stat.S_ISLNK(st.st_mode):
        result.update(type="symlink", target=os.readlink(path))
    elif stat.S_ISREG(st.st_mode):
        with open(path, "rb") as stream:
            result.update(type="file", sha256=hashlib.sha256(stream.read()).hexdigest(),
                          size=st.st_size)
    elif stat.S_ISDIR(st.st_mode):
        result.update(type="directory", entries={
            name: snapshot(os.path.join(path, name)) for name in sorted(os.listdir(path))})
    else:
        result.update(type="special", kind=stat.S_IFMT(st.st_mode))
    # atime changes when the oracle reads a file; inode/ctime may legitimately
    # change on restore. Neither is used as an equality oracle.
    if hasattr(os, "listxattr"):
        result["xattrs"] = {key: os.getxattr(path, key, follow_symlinks=False).hex()
                            for key in sorted(os.listxattr(path, follow_symlinks=False))}
    return result


def check_snapshot(expected_files, actual_path):
    actual = snapshot(actual_path)
    expected = [json.loads(Path(path).read_text()) for path in expected_files]
    if actual not in expected:
        print(f"Snapshot mismatch: {actual_path}\nexpected: {expected}\nactual: {actual}",
              file=sys.stderr)
        return False
    return True


def journal_retained(before, current):
    old = os.lstat(before)
    try:
        new = os.lstat(current)
    except FileNotFoundError:
        # The subject disappearing is a failed assertion, not an oracle crash.
        return False
    if not stat.S_ISREG(new.st_mode):
        return False
    previous = Path(before).read_bytes()
    data = Path(current).read_bytes()
    return (bool(previous) and data.startswith(previous) and data.endswith(b"\n")
            and (stat.S_IMODE(old.st_mode), old.st_uid, old.st_gid)
            == (stat.S_IMODE(new.st_mode), new.st_uid, new.st_gid))


def check_observer(run_dir, observer_dir, required):
    run = Path(run_dir)
    mapping = dict(line.split("\t") for line in
                   (Path(observer_dir) / "real-tools").read_text().splitlines())
    actual = collections.Counter()
    wrappers = collections.Counter()
    descriptors = collections.Counter()
    descriptor_times = []
    python_file = Path(observer_dir) / "python-real"
    python_real = os.path.realpath(python_file.read_text().strip()) if python_file.exists() else None
    traces = list(run.glob("trace.*"))
    if not traces:
        raise ProbeInfrastructureError("No strace output: observer was not exercised")
    for trace in traces:
        python_process = False
        for raw in trace.read_text().splitlines():
            stamp = re.match(r"^(\d+\.\d+) (.*)$", raw)
            line = stamp[2] if stamp else raw
            if python_process and re.match(r"^(unlinkat|fchmod|fchown)\(", line):
                if not stamp or not re.search(r"\)\s+= (?:0|-1 \w+.*)$", line):
                    raise ProbeInfrastructureError("Incomplete descriptor syscall observation")
                kind = "py-rmdir" if line.startswith("unlinkat(") and "AT_REMOVEDIR" in line else \
                       "py-unlink" if line.startswith("unlinkat(") else "py-" + line.split("(", 1)[0]
                descriptors[kind] += 1
                descriptor_times.append(decimal.Decimal(stamp[1]))
            if not line.startswith("execve("):
                continue
            match = re.match(r'execve\(("(?:[^"\\]|\\.)*"),.*\)\s+= 0$', line)
            if not match:
                # Failed PATH probes are normal; unparsed successful/unfinished
                # executions must not silently weaken coverage.
                if re.search(r"= -1 \w+", line):
                    continue
                raise ValueError(f"Unparsed execve: {line}")
            executable = ast.literal_eval(match.group(1))
            python_process = python_real is not None and os.path.realpath(executable) == python_real
            for tool, real in mapping.items():
                if (Path(executable).name == tool
                        and os.path.realpath(executable) == os.path.realpath(real)):
                    actual[tool] += 1
                if executable == str(Path(observer_dir) / tool):
                    wrappers[tool] += 1
    events = collections.Counter()
    safe = True
    if descriptor_times:
        stopped = run / "stopped"
        if not stopped.exists():
            print("Python filesystem mutation without a confirmed stop barrier", file=sys.stderr)
            safe = False
        else:
            barriers = [decimal.Decimal(t) for t in stopped.read_text().splitlines()]
            if not barriers or min(descriptor_times) <= min(barriers):
                print("Python filesystem mutation preceded confirmed stop", file=sys.stderr)
                safe = False
    for line in (run / "events").read_text().splitlines():
        tool, state = line.split("\t")
        events[tool] += 1
        if state != "inactive":
            print(f"Mutation while service state is {state}: {tool}", file=sys.stderr)
            safe = False
    # Detect absolute-path / command invocations bypassing the PATH wrappers.
    if actual != events or wrappers != events:
        print(f"Observer bypass/missing events: actual={actual}, wrappers={wrappers}, "
              f"events={events}", file=sys.stderr)
        safe = False
    for tool in required:
        if (descriptors if tool.startswith("py-") else events)[tool] == 0:
            print(f"Expected operation was not observed: {tool}", file=sys.stderr)
            safe = False
    return safe


def main():
    command, *args = sys.argv[1:]
    if command == "snapshot":
        print(json.dumps(snapshot(args[0]), sort_keys=True))
        return True
    if command == "check":
        return check_snapshot(args[:-1], args[-1])
    if command == "journal":
        return journal_retained(*args)
    if command == "observer":
        return check_observer(args[0], args[1], args[2:])
    raise ValueError(f"Unknown command: {command}")


if __name__ == "__main__":
    try:
        sys.exit(0 if main() else 1)
    except (OSError, ProbeInfrastructureError) as error:
        print(f"Oracle infrastructure error: {error}", file=sys.stderr)
        sys.exit(3)
    except Exception as error:
        # Invalid inputs and unexpected probe bugs must never become exit 1.
        print(f"Oracle execution error ({type(error).__name__}): {error}", file=sys.stderr)
        sys.exit(2)
