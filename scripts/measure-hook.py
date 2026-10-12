#!/usr/bin/env python3
# measure-hook.py — how long does one hook cost the agent?
#
# Usage: PERCH_HOME=<folder of a running test app> scripts/measure-hook.py [count]
#
# Runs the installed helper the way an agent does for an ordinary (fire-and-forget) event:
# start the program, hand it a captured PreToolUse payload on stdin, wait for it to exit.
# The time measured is the whole of that, as the agent experiences it, including starting the
# process. Prints the median and the slow end. The goal is under 15 ms.

import os, statistics, subprocess, sys, time

home = os.environ.get("PERCH_HOME")
if not home:
    sys.exit("set PERCH_HOME to the folder of a running test app")
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
helper = os.path.join(home, "bin", "perch-hook")
payload = open(os.path.join(root, "Fixtures", "claude", "hooks", "PreToolUse.Bash.json"), "rb").read()
count = int(sys.argv[1]) if len(sys.argv) > 1 else 200
environment = {"PERCH_HOME": home}

def one(arguments):
    started = time.perf_counter()
    result = subprocess.run([helper] + arguments, input=payload, env=environment, capture_output=True)
    elapsed = (time.perf_counter() - started) * 1000
    if result.returncode != 0 or result.stdout or result.stderr:
        sys.exit(f"the helper misbehaved: status {result.returncode}, output {result.stdout!r} {result.stderr!r}")
    return elapsed

def report(label, times):
    times = sorted(times)
    print(f"{label}: median {statistics.median(times):.1f} ms, mean {statistics.mean(times):.1f} ms, "
          f"95th percentile {times[int(len(times) * 0.95) - 1]:.1f} ms, slowest {times[-1]:.1f} ms, fastest {times[0]:.1f} ms (n={len(times)})")

arguments = ["--agent", "claude", "--event", "PreToolUse", "--pid", str(os.getpid())]
first = one(arguments)
print(f"first run (cold): {first:.1f} ms")
report("helper to running app ", [one(arguments) for _ in range(count)])
# For comparison: the cost of starting any small program at all on this Mac.
started_times = []
for _ in range(count):
    started = time.perf_counter()
    subprocess.run(["/usr/bin/true"], input=payload, env=environment, capture_output=True)
    started_times.append((time.perf_counter() - started) * 1000)
report("starting /usr/bin/true", started_times)
