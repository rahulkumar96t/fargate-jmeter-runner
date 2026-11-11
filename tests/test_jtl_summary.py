import csv
import json
import shutil
from pathlib import Path

import pytest

import jtl_summary
from jtl_summary import EXIT_FAILED_CHECKS, EXIT_PASSED, EXIT_USAGE, Threshold, percentile

FIXTURES = Path(__file__).parent / "fixtures"
INJECTORS = [FIXTURES / "injector-0.jtl", FIXTURES / "injector-1.jtl"]


@pytest.fixture
def summary():
    return jtl_summary.summarise(INJECTORS)


# --- percentile ---------------------------------------------------------------


@pytest.mark.parametrize(
    ("pct", "expected"),
    [(50, 500), (90, 900), (95, 1000), (99, 1000), (100, 1000), (10, 100), (1, 100)],
)
def test_percentile_uses_nearest_rank(pct, expected):
    values = [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]
    assert percentile(values, pct) == expected


def test_percentile_of_single_value():
    assert percentile([42], 99) == 42


@pytest.mark.parametrize("pct", [0, -1, 101])
def test_percentile_rejects_out_of_range(pct):
    with pytest.raises(ValueError):
        percentile([1, 2, 3], pct)


def test_percentile_rejects_empty():
    with pytest.raises(ValueError):
        percentile([], 50)


# --- statistics ---------------------------------------------------------------


def test_overall_statistics_across_injectors(summary):
    overall = summary["overall"]
    assert overall["count"] == 13
    assert overall["errors"] == 2
    assert overall["error_pct"] == pytest.approx(15.385)
    assert overall["avg_ms"] == pytest.approx(884.62)
    assert (overall["min_ms"], overall["max_ms"]) == (100, 3000)
    assert (overall["p50_ms"], overall["p90_ms"], overall["p95_ms"], overall["p99_ms"]) == (
        700,
        2000,
        3000,
        3000,
    )


def test_throughput_uses_first_start_to_last_end(summary):
    # First sample starts at t=0, the last one ends at t=5 s: 13 samples / 5 s.
    assert summary["overall"]["throughput_rps"] == pytest.approx(2.6)
    assert summary["overall"]["start_ms"] == 1_700_000_000_000
    assert summary["overall"]["end_ms"] == 1_700_000_005_000


def test_per_label_statistics(summary):
    home, login = summary["labels"]["home"], summary["labels"]["login"]
    assert list(summary["labels"]) == ["home", "login"]

    assert home["count"] == 10
    assert home["error_pct"] == pytest.approx(10.0)
    assert home["avg_ms"] == pytest.approx(550.0)
    assert (home["p50_ms"], home["p90_ms"], home["p95_ms"]) == (500, 900, 1000)
    assert home["throughput_rps"] == pytest.approx(2.0)

    assert login["count"] == 3
    assert login["errors"] == 1
    assert login["error_pct"] == pytest.approx(33.333)
    assert (login["p50_ms"], login["p90_ms"]) == (2000, 3000)
    # login samples span 0.5 s .. 5 s.
    assert login["throughput_rps"] == pytest.approx(0.667)


def test_quoted_multiline_failure_message_is_one_sample(summary):
    # injector-0 has a failureMessage with an embedded comma, quotes and newline.
    assert summary["malformed_rows"] == 0
    assert summary["labels"]["login"]["count"] == 3


def test_malformed_rows_are_skipped_and_counted():
    result = jtl_summary.summarise([FIXTURES / "malformed.jtl"])
    assert result["overall"]["count"] == 1
    assert result["malformed_rows"] == 2


def test_minimal_column_set_is_enough():
    result = jtl_summary.summarise([FIXTURES / "minimal-columns.jtl"])
    assert result["overall"]["count"] == 2
    assert result["overall"]["errors"] == 0
    assert result["overall"]["avg_ms"] == pytest.approx(200.0)


# --- merging ------------------------------------------------------------------


def test_merged_jtl_has_one_header_and_every_sample(tmp_path):
    merged = tmp_path / "merged.jtl"
    jtl_summary.summarise(INJECTORS, merged_out=merged)

    with merged.open(newline="") as handle:
        rows = list(csv.reader(handle))
    header, samples = rows[0], rows[1:]
    assert header[:4] == ["timeStamp", "elapsed", "label", "responseCode"]
    assert sum(1 for row in rows if row == header) == 1
    assert len(samples) == 13
    assert all(len(row) == len(header) for row in samples)


def test_merged_jtl_prefixes_thread_names_with_the_injector(tmp_path):
    merged = tmp_path / "merged.jtl"
    jtl_summary.summarise(INJECTORS, merged_out=merged)

    with merged.open(newline="") as handle:
        threads = {row["threadName"] for row in csv.DictReader(handle)}
    assert threads == {
        "injector-0 Users 1-1",
        "injector-0 Users 1-2",
        "injector-1 Users 1-1",
        "injector-1 Users 1-2",
    }


def test_merged_jtl_keeps_multiline_fields_intact(tmp_path):
    merged = tmp_path / "merged.jtl"
    jtl_summary.summarise(INJECTORS, merged_out=merged)

    with merged.open(newline="") as handle:
        messages = [row["failureMessage"] for row in csv.DictReader(handle) if row["failureMessage"]]
    assert 'Expected "200",\ngot 500' in messages


def test_merged_jtl_is_identical_input_for_a_resummary(tmp_path):
    merged = tmp_path / "merged.jtl"
    first = jtl_summary.summarise(INJECTORS, merged_out=merged)
    second = jtl_summary.summarise([merged])
    assert second["overall"] == first["overall"]
    assert second["labels"] == first["labels"]


def test_header_mismatch_is_rejected():
    with pytest.raises(jtl_summary.JtlError, match="columns differ"):
        jtl_summary.summarise([FIXTURES / "injector-0.jtl", FIXTURES / "minimal-columns.jtl"])


def test_file_without_header_is_rejected():
    with pytest.raises(jtl_summary.JtlError, match="missing column"):
        jtl_summary.summarise([FIXTURES / "no-header.jtl"])


def test_directories_expand_to_sorted_jtl_files(tmp_path):
    for source in reversed(INJECTORS):
        shutil.copy(source, tmp_path / source.name)
    (tmp_path / "jmeter-0.log").write_text("not a result file")
    assert [p.name for p in jtl_summary.discover_inputs([tmp_path])] == ["injector-0.jtl", "injector-1.jtl"]


def test_empty_input_file_counts_as_input_without_samples(tmp_path):
    empty = tmp_path / "injector-2.jtl"
    empty.write_text("")
    result = jtl_summary.summarise([*INJECTORS, empty])
    assert result["overall"]["count"] == 13
    assert result["inputs"] == ["injector-0.jtl", "injector-1.jtl", "injector-2.jtl"]


# --- thresholds ---------------------------------------------------------------


@pytest.mark.parametrize(
    ("text", "metric", "op", "limit"),
    [
        ("p95>800", "p95", ">", 800.0),
        ("errors>1%", "errors", ">", 1.0),
        (" p99 >= 1500ms ", "p99", ">=", 1500.0),
        ("rps<50", "rps", "<", 50.0),
        ("avg<=250.5", "avg", "<=", 250.5),
    ],
)
def test_threshold_parsing(text, metric, op, limit):
    threshold = Threshold.parse(text)
    assert (threshold.metric, threshold.op, threshold.limit) == (metric, op, limit)


@pytest.mark.parametrize("text", ["p95", "p95=>800", "p97>800", "p95>800%", "rps>5ms", "errors>abc", ""])
def test_threshold_parsing_rejects_garbage(text):
    with pytest.raises(ValueError):
        Threshold.parse(text)


def test_comma_separated_thresholds():
    parsed = jtl_summary.parse_thresholds(["p95>800,errors>1%", "rps<10"])
    assert [t.expression for t in parsed] == ["p95>800", "errors>1%", "rps<10"]


def test_threshold_without_data_is_breached():
    check = Threshold.parse("p95>800").evaluate({"p95_ms": None})
    assert check["breached"] is True


def test_verdict_lists_every_breach(summary):
    overall = summary["overall"]
    thresholds = jtl_summary.parse_thresholds(["p95>2500", "errors>20%", "rps<5"])
    verdict = jtl_summary.build_verdict(overall, thresholds, inputs=2, expected_inputs=2)
    assert verdict["passed"] is False
    assert [c["breached"] for c in verdict["checks"]] == [True, False, True]
    assert verdict["reason"] == "p95>2500 breached (actual 3000); rps<5 breached (actual 2.6)"


def test_verdict_fails_when_injector_results_are_missing(summary):
    verdict = jtl_summary.build_verdict(summary["overall"], [], inputs=2, expected_inputs=3)
    assert verdict["passed"] is False
    assert "only 2 of 3 injector result files present" in verdict["reason"]


def test_verdict_overall_keys_are_always_present_even_without_samples():
    # The state machine formats these keys into the notification; a missing key
    # would be a runtime error there, so they must exist (as null) without data.
    result = jtl_summary.summarise([], expected_inputs=2)
    verdict = result["verdict"]
    assert verdict["passed"] is False
    assert set(verdict["overall"]) == {
        "count",
        "error_pct",
        "avg_ms",
        "p50_ms",
        "p90_ms",
        "p95_ms",
        "p99_ms",
        "throughput_rps",
    }
    assert verdict["overall"]["count"] == 0
    assert verdict["overall"]["p95_ms"] is None
    assert "no samples recorded" in verdict["reason"]


# --- command line -------------------------------------------------------------


def run_cli(*args):
    return jtl_summary.main([str(a) for a in args])


def test_cli_passes_and_writes_summary_and_verdict(tmp_path, capsys):
    out, verdict_out = tmp_path / "summary.json", tmp_path / "verdict.json"
    rc = run_cli(
        *INJECTORS,
        "--out",
        out,
        "--verdict-out",
        verdict_out,
        "--fail-if",
        "p95>5000,errors>20%",
        "--expect-inputs",
        2,
    )
    assert rc == EXIT_PASSED
    summary = json.loads(out.read_text())
    verdict = json.loads(verdict_out.read_text())
    assert summary["overall"]["count"] == 13
    assert summary["verdict"] == verdict
    assert verdict["passed"] is True
    assert verdict["reason"] == "all checks passed"
    assert "labels" not in verdict
    table = capsys.readouterr().out
    assert "TOTAL" in table and "verdict: PASSED" in table


def test_cli_exits_1_on_breach(tmp_path):
    verdict_out = tmp_path / "verdict.json"
    rc = run_cli(*INJECTORS, "--fail-if", "p95>800", "--verdict-out", verdict_out, "-q")
    assert rc == EXIT_FAILED_CHECKS
    assert json.loads(verdict_out.read_text())["checks"][0] == {
        "expression": "p95>800",
        "actual": 3000,
        "breached": True,
    }


def test_cli_exits_2_on_bad_threshold(capsys):
    assert run_cli(*INJECTORS, "--fail-if", "p95 above 800") == EXIT_USAGE
    assert "cannot parse threshold" in capsys.readouterr().err


def test_cli_exits_2_on_missing_file(tmp_path, capsys):
    assert run_cli(tmp_path / "nope.jtl") == EXIT_USAGE
    assert "no such file" in capsys.readouterr().err


def test_cli_exits_2_on_mismatched_headers():
    assert run_cli(FIXTURES / "injector-0.jtl", FIXTURES / "minimal-columns.jtl") == EXIT_USAGE


def test_cli_with_no_inputs_still_writes_a_failed_verdict(tmp_path):
    verdict_out = tmp_path / "verdict.json"
    rc = run_cli("--expect-inputs", 3, "--verdict-out", verdict_out, "-q")
    assert rc == EXIT_FAILED_CHECKS
    verdict = json.loads(verdict_out.read_text())
    assert verdict["inputs"] == 0
    assert verdict["expected_inputs"] == 3
