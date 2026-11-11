#!/usr/bin/env python3
"""Merge JMeter CSV result files (JTL) and summarise them.

Reads one or more JTL files (or directories of *.jtl files), optionally writes a
single merged JTL for ``jmeter -g``, and writes:

* ``summary.json``: count, error %, avg/min/max, p50/p90/p95/p99 and throughput,
  overall and per sampler label, plus the verdict;
* ``verdict.json``: a small, bounded pass/fail document for automation.

Thresholds are given as ``--fail-if p95>800 --fail-if errors>1%`` (or comma
separated). Exit codes: 0 all checks passed, 1 a check failed, 2 bad input/usage.

Only the standard library is used, so the script runs as-is inside the image.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
from array import array
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

EXIT_PASSED = 0
EXIT_FAILED_CHECKS = 1
EXIT_USAGE = 2

REQUIRED_COLUMNS = ("timeStamp", "elapsed", "label", "success")
PERCENTILES = (50, 90, 95, 99)
# Keys copied into verdict.json; the state machine formats them into notifications.
VERDICT_KEYS = ("count", "error_pct", "avg_ms", "p50_ms", "p90_ms", "p95_ms", "p99_ms", "throughput_rps")

# Threshold metric name -> key in a stats dict.
METRICS = {
    "count": "count",
    "errors": "error_pct",
    "error_pct": "error_pct",
    "avg": "avg_ms",
    "min": "min_ms",
    "max": "max_ms",
    "p50": "p50_ms",
    "p90": "p90_ms",
    "p95": "p95_ms",
    "p99": "p99_ms",
    "rps": "throughput_rps",
    "throughput": "throughput_rps",
}
LATENCY_METRICS = {"avg", "min", "max", "p50", "p90", "p95", "p99"}
PERCENT_METRICS = {"errors", "error_pct"}

OPERATORS = {
    ">": lambda actual, limit: actual > limit,
    ">=": lambda actual, limit: actual >= limit,
    "<": lambda actual, limit: actual < limit,
    "<=": lambda actual, limit: actual <= limit,
}

_THRESHOLD_RE = re.compile(
    r"^\s*(?P<metric>[a-z0-9_]+)\s*(?P<op>>=|<=|>|<)\s*(?P<value>\d+(?:\.\d+)?)\s*(?P<unit>%|ms)?\s*$"
)


class JtlError(Exception):
    """Input that cannot be summarised (missing columns, mismatched headers...)."""


def percentile(sorted_values: Sequence[int], pct: float) -> int:
    """Nearest-rank percentile of an ascending sequence (no interpolation).

    The value returned is always an observed sample, which is what people expect
    when they read "p95 = 812 ms".
    """
    if not sorted_values:
        raise ValueError("percentile of an empty sequence")
    if not 0 < pct <= 100:
        raise ValueError(f"percentile must be in (0, 100], got {pct}")
    rank = math.ceil(pct / 100 * len(sorted_values))
    return sorted_values[max(rank, 1) - 1]


@dataclass
class Stats:
    """Accumulates samples of one label (or of all labels)."""

    elapsed: array = field(default_factory=lambda: array("q"))
    errors: int = 0
    first_start: int | None = None
    last_end: int | None = None

    def add(self, timestamp: int, elapsed: int, success: bool) -> None:
        self.elapsed.append(elapsed)
        if not success:
            self.errors += 1
        end = timestamp + elapsed
        if self.first_start is None or timestamp < self.first_start:
            self.first_start = timestamp
        if self.last_end is None or end > self.last_end:
            self.last_end = end

    def to_dict(self) -> dict[str, Any]:
        count = len(self.elapsed)
        result: dict[str, Any] = {
            "count": count,
            "errors": self.errors,
            "error_pct": round(100.0 * self.errors / count, 3) if count else None,
            "avg_ms": None,
            "min_ms": None,
            "max_ms": None,
            **{f"p{p}_ms": None for p in PERCENTILES},
            "throughput_rps": None,
            "start_ms": self.first_start,
            "end_ms": self.last_end,
        }
        if not count:
            return result
        ordered = sorted(self.elapsed)
        # A window of at least 1 ms keeps a single instantaneous sample finite.
        window_s = max(self.last_end - self.first_start, 1) / 1000.0
        result.update(
            avg_ms=round(sum(ordered) / count, 2),
            min_ms=ordered[0],
            max_ms=ordered[-1],
            throughput_rps=round(count / window_s, 3),
            **{f"p{p}_ms": percentile(ordered, p) for p in PERCENTILES},
        )
        return result


@dataclass(frozen=True)
class Threshold:
    """A "fail if" rule, for example ``p95>800`` or ``errors>1%``."""

    expression: str
    metric: str
    op: str
    limit: float

    @classmethod
    def parse(cls, text: str) -> Threshold:
        match = _THRESHOLD_RE.match(text)
        if not match:
            raise ValueError(f"cannot parse threshold {text!r}; expected e.g. p95>800 or errors>1%")
        metric, op, value, unit = match.group("metric", "op", "value", "unit")
        if metric not in METRICS:
            known = ", ".join(sorted(METRICS))
            raise ValueError(f"unknown metric {metric!r} in {text!r}; known metrics: {known}")
        if unit == "%" and metric not in PERCENT_METRICS:
            raise ValueError(f"'%' only applies to the errors metric, not {metric!r}")
        if unit == "ms" and metric not in LATENCY_METRICS:
            raise ValueError(f"'ms' only applies to latency metrics, not {metric!r}")
        expression = f"{metric}{op}{value}{unit or ''}"
        return cls(expression=expression, metric=metric, op=op, limit=float(value))

    def evaluate(self, stats: dict[str, Any]) -> dict[str, Any]:
        actual = stats.get(METRICS[self.metric])
        # No data means the check cannot pass.
        breached = actual is None or OPERATORS[self.op](actual, self.limit)
        return {"expression": self.expression, "actual": actual, "breached": breached}


def parse_thresholds(expressions: Iterable[str]) -> list[Threshold]:
    thresholds = []
    for expression in expressions:
        for part in expression.split(","):
            if part.strip():
                thresholds.append(Threshold.parse(part))
    return thresholds


def discover_inputs(paths: Iterable[Path]) -> list[Path]:
    """Expand directories to their *.jtl files; keep a stable, sorted order."""
    files: list[Path] = []
    for path in paths:
        if path.is_dir():
            files.extend(sorted(p for p in path.glob("*.jtl") if p.is_file()))
        elif path.is_file():
            files.append(path)
        else:
            raise JtlError(f"{path}: no such file or directory")
    return files


@dataclass
class Aggregate:
    header: list[str] | None = None
    overall: Stats = field(default_factory=Stats)
    labels: dict[str, Stats] = field(default_factory=dict)
    malformed_rows: int = 0


def _read_into(path: Path, aggregate: Aggregate, writer: Any | None, tag_threads: bool) -> None:
    with path.open(newline="", encoding="utf-8", errors="replace") as handle:
        reader = csv.reader(handle)
        header = next(reader, None)
        if header is None:
            return  # empty file: an injector that never wrote anything
        missing = [c for c in REQUIRED_COLUMNS if c not in header]
        if missing:
            raise JtlError(
                f"{path}: missing column(s) {', '.join(missing)}; JTLs must be CSV with a "
                "header line (jmeter.save.saveservice.print_field_names=true)"
            )
        if aggregate.header is None:
            aggregate.header = header
            if writer is not None:
                writer.writerow(header)
        elif header != aggregate.header:
            raise JtlError(f"{path}: columns differ from the first input; cannot merge")

        idx = {name: header.index(name) for name in REQUIRED_COLUMNS}
        thread_idx = header.index("threadName") if "threadName" in header else None
        tag = path.stem
        for row in reader:
            if len(row) != len(header):
                aggregate.malformed_rows += 1
                continue
            try:
                timestamp = int(row[idx["timeStamp"]])
                elapsed = int(row[idx["elapsed"]])
            except ValueError:
                aggregate.malformed_rows += 1
                continue
            success = row[idx["success"]].strip().lower() == "true"
            label = row[idx["label"]]
            aggregate.overall.add(timestamp, elapsed, success)
            aggregate.labels.setdefault(label, Stats()).add(timestamp, elapsed, success)
            if writer is not None:
                if tag_threads and thread_idx is not None:
                    # Thread names repeat on every injector ("Users 1-1"); prefix them
                    # so the dashboard's active-threads graph counts injectors apart.
                    row[thread_idx] = f"{tag} {row[thread_idx]}"
                writer.writerow(row)


def aggregate_files(
    files: Sequence[Path], merged_out: Path | None = None, tag_threads: bool = True
) -> Aggregate:
    aggregate = Aggregate()
    if merged_out is None:
        for path in files:
            _read_into(path, aggregate, None, tag_threads)
        return aggregate
    merged_out.parent.mkdir(parents=True, exist_ok=True)
    with merged_out.open("w", newline="", encoding="utf-8") as out:
        writer = csv.writer(out, lineterminator="\n")
        for path in files:
            _read_into(path, aggregate, writer, tag_threads)
    return aggregate


def build_verdict(
    overall: dict[str, Any],
    thresholds: Sequence[Threshold],
    inputs: int,
    expected_inputs: int | None,
) -> dict[str, Any]:
    reasons: list[str] = []
    if expected_inputs is not None and inputs < expected_inputs:
        reasons.append(f"only {inputs} of {expected_inputs} injector result files present")
    if overall["count"] == 0:
        reasons.append("no samples recorded")
    checks = [t.evaluate(overall) for t in thresholds]
    for check in checks:
        if check["breached"]:
            reasons.append(f"{check['expression']} breached (actual {check['actual']})")
    return {
        "passed": not reasons,
        "reason": "; ".join(reasons) if reasons else "all checks passed",
        "inputs": inputs,
        "expected_inputs": expected_inputs,
        "checks": checks,
        "overall": {key: overall[key] for key in VERDICT_KEYS},
    }


def summarise(
    files: Sequence[Path],
    thresholds: Sequence[Threshold] = (),
    expected_inputs: int | None = None,
    merged_out: Path | None = None,
) -> dict[str, Any]:
    aggregate = aggregate_files(files, merged_out)
    overall = aggregate.overall.to_dict()
    return {
        "inputs": [p.name for p in files],
        "malformed_rows": aggregate.malformed_rows,
        "overall": overall,
        "labels": {label: aggregate.labels[label].to_dict() for label in sorted(aggregate.labels)},
        "verdict": build_verdict(overall, thresholds, len(files), expected_inputs),
    }


def format_table(summary: dict[str, Any]) -> str:
    rows = [(label, stats) for label, stats in summary["labels"].items()]
    rows.append(("TOTAL", summary["overall"]))
    width = max([len("label"), *(len(label) for label, _ in rows)])
    columns = ("count", "error_pct", "avg_ms", "p95_ms", "p99_ms", "throughput_rps")
    titles = ("count", "err %", "avg ms", "p95 ms", "p99 ms", "req/s")
    lines = [f"{'label':<{width}}  " + "  ".join(f"{t:>9}" for t in titles)]
    for label, stats in rows:
        cells = ("-" if stats[c] is None else str(stats[c]) for c in columns)
        lines.append(f"{label:<{width}}  " + "  ".join(f"{c:>9}" for c in cells))
    verdict = summary["verdict"]
    lines.append(f"verdict: {'PASSED' if verdict['passed'] else 'FAILED'} ({verdict['reason']})")
    return "\n".join(lines)


def _write_json(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Merge JMeter JTL (CSV) files and compute per-label latency statistics.",
    )
    parser.add_argument("inputs", nargs="*", type=Path, help="JTL files or directories of *.jtl")
    parser.add_argument("-o", "--out", type=Path, help="write the full summary JSON here")
    parser.add_argument("--verdict-out", type=Path, help="write the compact verdict JSON here")
    parser.add_argument("--merged-out", type=Path, help="write all samples to one JTL (for jmeter -g)")
    parser.add_argument(
        "--fail-if",
        action="append",
        default=[],
        metavar="EXPR",
        help="fail when the overall metric matches, e.g. p95>800, errors>1%%, rps<50 (repeatable)",
    )
    parser.add_argument(
        "--expect-inputs",
        type=int,
        metavar="N",
        help="fail when fewer than N input files are present (one per injector)",
    )
    parser.add_argument("-q", "--quiet", action="store_true", help="do not print the table")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        thresholds = parse_thresholds(args.fail_if)
        files = discover_inputs(args.inputs)
        summary = summarise(files, thresholds, args.expect_inputs, args.merged_out)
    except (ValueError, JtlError, OSError) as exc:
        print(f"jtl_summary: error: {exc}", file=sys.stderr)
        return EXIT_USAGE

    if args.out:
        _write_json(args.out, summary)
    if args.verdict_out:
        _write_json(args.verdict_out, summary["verdict"])
    if not args.quiet:
        print(format_table(summary))
    if summary["malformed_rows"]:
        print(f"jtl_summary: skipped {summary['malformed_rows']} malformed row(s)", file=sys.stderr)
    return EXIT_PASSED if summary["verdict"]["passed"] else EXIT_FAILED_CHECKS


if __name__ == "__main__":
    sys.exit(main())
