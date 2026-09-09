#!/usr/bin/env python3
"""Build and measure the same Nim source with three exception implementations."""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import platform
import random
import shlex
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
SOURCE = Path(__file__).with_name("exceptionbench.nim")
MODES = ("native", "setjmp", "goto")


def command(args, cwd=ROOT):
    result = subprocess.run([str(arg) for arg in args], cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f"{shlex.join(map(str, args))}\n{result.stdout}{result.stderr}")
    return result.stdout


def positive_int(value):
    result = int(value)
    if result <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_nim = ROOT / "bin" / "nim_native"
    parser.add_argument("--nim", default=str(default_nim if default_nim.exists()
                                             else ROOT / "bin" / "nim"))
    parser.add_argument("--cc", choices=("clang", "gcc"), default="clang")
    parser.add_argument("--mm", choices=("arc", "orc", "refc"), default="arc")
    parser.add_argument("--samples", type=positive_int, default=5)
    parser.add_argument("--seconds", type=float, default=0.15,
                        help="target seconds of timed work per sample")
    parser.add_argument("--depth", type=positive_int, default=16)
    parser.add_argument("--payload", choices=("reuse", "fresh", "both"), default="both")
    parser.add_argument("--out", type=Path, default=ROOT / "nimcache" / "exception-bench")
    parser.add_argument("--nim-flag", action="append", default=[],
                        help="extra common build flag; use --nim-flag=--gcc.exe=gcc-16")
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or args.seconds <= 0 or args.depth > 128:
        parser.error("--seconds must be positive and finite; --depth must be at most 128")
    nim = shutil.which(args.nim) or str(Path(args.nim).resolve())
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    common = ["c", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg", "-d:release",
              "--opt:speed", "--checks:off", "--assertions:on", "--stackTrace:off",
              "--lineTrace:off", "--threads:off", "--hints:off",
              f"--cc:{args.cc}", f"--mm:{args.mm}",
              "--passC:-fno-optimize-sibling-calls", *args.nim_flag]
    compiler_exe = args.cc
    for flag in args.nim_flag:
        for separator in (":", "="):
            prefix = f"--{args.cc}.exe{separator}"
            if flag.startswith(prefix):
                compiler_exe = flag[len(prefix):]
    cpu = platform.processor() or platform.machine()
    if platform.system() == "Darwin":
        cpu = command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
    metadata = {"cpu": cpu, "c_compiler": command([compiler_exe, "--version"]).strip(),
                "environment": {key: os.environ.get(key, "")
                                for key in ("CC", "CXX", "CFLAGS", "CXXFLAGS")},
                "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "platform": platform.platform(), "machine": platform.machine(),
                "nim": command([nim, "--version"]).strip(),
                "settings": vars(args) | {"out": str(out)}, "builds": {}}
    executables = {}
    for mode in MODES:
        executable = out / f"exceptionbench-{mode}"
        build = [nim, *common, f"--exceptions:{mode}", f"-d:expectedMode={mode}",
                 f"--nimcache:{out / ('cache-' + mode)}", f"-o:{executable}", SOURCE]
        print(f"Building {mode}...", flush=True)
        start = time.monotonic()
        command(build)
        metadata["builds"][mode] = {"command": list(map(str, build)),
                                    "seconds": time.monotonic() - start,
                                    "executable_bytes": executable.stat().st_size}
        executables[mode] = executable
        if mode == "native":
            generated = "\n".join(path.read_text() for path in
                                  (out / "cache-native").glob("*.c"))
            if "nimNativeTry(" not in generated or "nimNativeThrow(" not in generated:
                raise RuntimeError("native runtime calls were not found in generated C")

    cases = [("plain", "plain", 0, 0), ("try, no throw", "try", 0, 0),
             ("try, 1/1024 throws", "try", 0, 1024), ("try, every call throws", "try", 0, 1)]
    for kind in ("try", "cleanup"):
        label = "propagation" if kind == "try" else "finally each frame"
        for period, rate in ((0, "no throw"), (1024, "1/1024 throws"), (1, "every call throws")):
            cases.append((f"{label}, depth {args.depth}, {rate}", kind, args.depth, period))
    workloads = []
    for label, kind, depth, period in cases:
        payloads = ("reuse", "fresh") if args.payload == "both" and period else (
            "reuse" if args.payload == "both" else args.payload,)
        for payload in payloads:
            workloads.append((label, kind, depth, period, payload))

    def measure(mode, case, rounds):
        label, kind, depth, period, payload = case
        row = json.loads(command([executables[mode], kind, rounds, depth, period, payload]))
        if row["mode"] != mode or row["operations"] != rounds * 4096:
            raise RuntimeError(f"unexpected benchmark identity: {row}")
        row["ns_per_op"] = row["elapsed_ns"] / row["operations"]
        row["label"] = label
        return row

    records = []
    summaries = []
    rng = random.Random(20260909)
    try:
        for case in workloads:
            print(f"Measuring {case[0]} ({case[4]})...", flush=True)
            rounds = {}
            for mode in MODES:
                count = 1
                for _ in range(5):
                    probe = measure(mode, case, count)
                    elapsed = max(probe["elapsed_ns"] / 1e9, 1e-9)
                    if elapsed >= args.seconds * 0.8 or count == 1_000_000:
                        break
                    count = min(1_000_000, max(count + 1, math.ceil(count * args.seconds / elapsed)))
                rounds[mode] = count
            rows = {mode: [] for mode in MODES}
            for sample in range(args.samples):
                order = list(MODES)
                rng.shuffle(order)
                for mode in order:
                    row = measure(mode, case, rounds[mode])
                    row["sample"] = sample
                    records.append(row)
                    rows[mode].append(row["ns_per_op"])
            summaries.append({"workload": case[0], "payload": case[4], "modes": {
                mode: {"median_ns": statistics.median(values), "min_ns": min(values),
                       "max_ns": max(values), "rounds": rounds[mode]}
                for mode, values in rows.items()}})
    finally:
        (out / "results.json").write_text(json.dumps(
            {"metadata": metadata, "summaries": summaries, "samples": records}, indent=2) + "\n")

    lines = ["# Exception benchmark results", "", metadata["date"], "",
             f"{metadata['cpu']}; {metadata['platform']}; {args.cc}; {args.mm}; "
             "release; checks/traces/threads off.",
             f"Median of {args.samples} samples, approximately {args.seconds:g} s each. "
             "Values are ns per attempted operation; lower is better.", "",
             "| Workload | Payload | Native | Setjmp | Goto | Native / goto |",
             "|---|---|---:|---:|---:|---:|"]
    for summary in summaries:
        values = [summary["modes"][mode]["median_ns"] for mode in MODES]
        lines.append(f"| {summary['workload']} | {summary['payload']} | " +
                     " | ".join(f"{value:,.1f}" for value in values) +
                     f" | {values[0] / values[2]:.2f}x |")
    lines.extend(["", "A ratio above 1 means native took longer than goto.",
                  "Fresh includes exception allocation; reuse resets the existing payload's trace.",
                  "See results.json for raw samples, build commands, spread, and binary sizes.", ""])
    report = "\n".join(lines)
    (out / "results.md").write_text(report)
    print("\n" + report)
    print(f"Saved results to {out}")


if __name__ == "__main__":
    main()
