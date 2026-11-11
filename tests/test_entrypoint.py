import json
import signal
import subprocess
import sys
import time
from datetime import UTC, datetime, timedelta

import pytest
from support import FIXTURES, ROOT

ENTRYPOINT = ROOT / "docker" / "entrypoint.sh"
RUN_ID = "checkout-20261111T100000Z"


@pytest.fixture
def container(sandbox):
    """Environment the state machine would give the container."""
    sandbox.env.update(
        WORK_DIR=str(sandbox.root / "work"),
        JMETER_BIN="jmeter",
        PYTHON_BIN=sys.executable,
        SUMMARY_TOOL=str(ROOT / "tools" / "jtl_summary.py"),
        RUNNER_PROPERTIES=str(ROOT / "docker" / "runner.properties"),
        RESULTS_BUCKET="results",
        RUN_ID=RUN_ID,
    )
    return sandbox


@pytest.fixture
def injector(container):
    container.put("plans/checkout/checkout.jmx", "<jmeterTestPlan/>")
    container.put("plans/checkout/users.csv", "user,password\n")
    container.put("plans/other/other.jmx", "<jmeterTestPlan/>")
    container.env.update(
        PLAN_KEY="plans/checkout/checkout.jmx",
        TARGET_HOST="perf.example.com",
        INJECTOR_INDEX="1",
        INJECTOR_COUNT="2",
        THREADS="25",
        RAMP_UP_SECONDS="30",
        DURATION_SECONDS="120",
        FAKE_JMETER_JTL=str(FIXTURES / "injector-1.jtl"),
    )
    return container


# --- run mode -----------------------------------------------------------------


def test_run_downloads_plan_folder_runs_jmeter_and_uploads_results(injector):
    result = injector.run(ENTRYPOINT, "run", JMETER_PROPERTIES="think.ms=500, login.user=demo")
    assert result.returncode == 0, result.stderr

    work = injector.root / "work" / "plan"
    assert (work / "checkout.jmx").exists()
    assert (work / "users.csv").exists(), "CSV data files next to the plan must be downloaded"
    assert not (work / "other.jmx").exists(), "only the plan's own folder is downloaded"

    uploaded = injector.s3 / "jtl" / RUN_ID
    assert (uploaded / "injector-1.jtl").read_bytes() == (FIXTURES / "injector-1.jtl").read_bytes()
    assert (uploaded / "logs" / "jmeter-1.log").exists()


def test_run_passes_the_load_shape_as_jmeter_properties(injector):
    result = injector.run(ENTRYPOINT, "run", JMETER_PROPERTIES="think.ms=500, login.user=demo")
    assert result.returncode == 0, result.stderr

    [args] = injector.calls("jmeter.log")
    assert args[:2] == ["-n", "-t"]
    assert args[args.index("-q") + 1].endswith("runner.properties")
    for expected in (
        "-Jthreads=25",
        "-Jrampup=30",
        "-Jduration=120",
        "-Jtarget.host=perf.example.com",
        "-Jtarget.protocol=https",
        "-Jtarget.port=443",
        "-Jinjector.index=1",
        "-Jinjector.count=2",
        f"-Jrun.id={RUN_ID}",
        "-Jthink.ms=500",
        "-Jlogin.user=demo",
    ):
        assert expected in args


def test_run_waits_for_the_synchronised_start(injector):
    start_after = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    began = time.monotonic()
    result = injector.run(ENTRYPOINT, "run", START_AFTER=start_after, START_DELAY_SECONDS="3")
    assert result.returncode == 0, result.stderr
    assert time.monotonic() - began >= 1.0
    assert "for the synchronised start" in result.stderr


def test_run_starts_immediately_when_the_start_time_has_passed(injector):
    start_after = (datetime.now(UTC) - timedelta(minutes=5)).isoformat()
    result = injector.run(ENTRYPOINT, "run", START_AFTER=start_after, START_DELAY_SECONDS="60")
    assert result.returncode == 0, result.stderr
    assert "starting now" in result.stderr


def test_run_rejects_a_malformed_start_time(injector):
    result = injector.run(ENTRYPOINT, "run", START_AFTER="next tuesday")
    assert result.returncode == 1
    assert "not an ISO-8601 timestamp" in result.stderr


def test_failed_jmeter_uploads_partial_results_under_an_ignored_name(injector):
    result = injector.run(ENTRYPOINT, "run", FAKE_JMETER_EXIT="1")
    assert result.returncode == 1
    assert "JMeter exited with status 1" in result.stderr
    uploaded = injector.s3 / "jtl" / RUN_ID
    assert (uploaded / "injector-1.jtl.partial").exists()
    assert not (uploaded / "injector-1.jtl").exists()


def test_sigterm_stops_jmeter_and_keeps_partial_results(injector):
    # ECS StopTask (for example when the execution is aborted) sends SIGTERM.
    process = subprocess.Popen(
        ["bash", str(ENTRYPOINT), "run"],
        env={**injector.env, "FAKE_JMETER_SLEEP": "30"},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    jtl = injector.root / "work" / "out" / "injector-1.jtl"
    deadline = time.monotonic() + 15
    while not jtl.exists():
        assert time.monotonic() < deadline, "JMeter never started"
        time.sleep(0.05)

    process.send_signal(signal.SIGTERM)
    _, stderr = process.communicate(timeout=20)

    assert process.returncode == 1
    assert "received TERM" in stderr
    assert (injector.s3 / "jtl" / RUN_ID / "injector-1.jtl.partial").exists()
    assert not (injector.s3 / "jtl" / RUN_ID / "injector-1.jtl").exists()


def test_run_without_samples_fails(injector, tmp_path):
    header_only = tmp_path / "empty.jtl"
    header_only.write_text((FIXTURES / "injector-0.jtl").read_text().splitlines()[0] + "\n")
    result = injector.run(ENTRYPOINT, "run", FAKE_JMETER_JTL=str(header_only))
    assert result.returncode == 1
    assert "no samples" in result.stderr
    assert not (injector.s3 / "jtl" / RUN_ID / "injector-1.jtl").exists()


def test_run_fails_when_the_plan_is_missing(injector):
    result = injector.run(ENTRYPOINT, "run", PLAN_KEY="plans/checkout/missing.jmx")
    assert result.returncode == 1
    assert "not found" in result.stderr
    assert injector.calls("jmeter.log") == []


@pytest.mark.parametrize(
    "plan_key",
    [
        "plans/../secrets/x.jmx",
        "jtl/other-run/injector-0.jmx",
        "plans/checkout/checkout.xml",
        "plans/a b.jmx",
    ],
)
def test_run_rejects_plan_keys_outside_plans(injector, plan_key):
    result = injector.run(ENTRYPOINT, "run", PLAN_KEY=plan_key)
    assert result.returncode == 1
    assert "PLAN_KEY" in result.stderr
    assert injector.calls("aws.log") == []


@pytest.mark.parametrize("run_id", ["../other", "a/b", "x" * 81])
def test_run_rejects_run_ids_that_escape_the_prefix(injector, run_id):
    result = injector.run(ENTRYPOINT, "run", RUN_ID=run_id)
    assert result.returncode == 1
    assert "not a valid run id" in result.stderr


def test_run_rejects_malformed_jmeter_properties(injector):
    result = injector.run(ENTRYPOINT, "run", JMETER_PROPERTIES="think.ms=500,oops")
    assert result.returncode == 1
    assert "invalid JMETER_PROPERTIES entry 'oops'" in result.stderr


def test_run_rejects_non_numeric_load_settings(injector):
    result = injector.run(ENTRYPOINT, "run", THREADS="many")
    assert result.returncode == 1
    assert "THREADS must be a non-negative integer" in result.stderr


def test_run_requires_a_target(injector):
    env = dict(injector.env)
    del env["TARGET_HOST"]
    injector.env = env
    result = injector.run(ENTRYPOINT, "run")
    assert result.returncode == 1
    assert "TARGET_HOST is required" in result.stderr


# --- report mode --------------------------------------------------------------


@pytest.fixture
def finished_run(container):
    container.put(f"jtl/{RUN_ID}/injector-0.jtl", FIXTURES / "injector-0.jtl")
    container.put(f"jtl/{RUN_ID}/injector-1.jtl", FIXTURES / "injector-1.jtl")
    container.put(f"jtl/{RUN_ID}/injector-2.jtl.partial", FIXTURES / "malformed.jtl")
    container.put(f"jtl/{RUN_ID}/logs/jmeter-0.log", "log\n")
    container.put("jtl/other-run/injector-0.jtl", FIXTURES / "injector-0.jtl")
    return container


def read_report(sandbox, name):
    return json.loads((sandbox.s3 / "reports" / RUN_ID / name).read_text())


def test_report_merges_results_and_uploads_dashboard_summary_and_verdict(finished_run):
    result = finished_run.run(ENTRYPOINT, "report", EXPECTED_INJECTORS="2", FAIL_IF="p95>5000,errors>20%")
    assert result.returncode == 0, result.stderr

    summary = read_report(finished_run, "summary.json")
    assert summary["inputs"] == ["injector-0.jtl", "injector-1.jtl"], "partial results must be ignored"
    assert summary["overall"]["count"] == 13
    assert read_report(finished_run, "verdict.json")["passed"] is True
    assert (finished_run.s3 / "reports" / RUN_ID / "index.html").exists()

    [args] = finished_run.calls("jmeter.log")
    assert args[0] == "-g" and args[1].endswith("merged.jtl")


def test_report_uploads_the_verdict_last(finished_run):
    result = finished_run.run(ENTRYPOINT, "report", EXPECTED_INJECTORS="2")
    assert result.returncode == 0, result.stderr
    uploads = [call[-1] for call in finished_run.calls("aws.log") if call[:2] == ["s3", "cp"]]
    assert uploads[-1] == f"s3://results/reports/{RUN_ID}/verdict.json"


def test_threshold_breach_is_a_result_not_an_error(finished_run):
    result = finished_run.run(ENTRYPOINT, "report", EXPECTED_INJECTORS="2", FAIL_IF="p95>800")
    assert result.returncode == 0, result.stderr
    verdict = read_report(finished_run, "verdict.json")
    assert verdict["passed"] is False
    assert verdict["reason"] == "p95>800 breached (actual 3000)"
    assert (finished_run.s3 / "reports" / RUN_ID / "index.html").exists()


def test_missing_injector_results_fail_the_verdict(finished_run):
    result = finished_run.run(ENTRYPOINT, "report", EXPECTED_INJECTORS="3")
    assert result.returncode == 0, result.stderr
    verdict = read_report(finished_run, "verdict.json")
    assert verdict["passed"] is False
    assert verdict["reason"] == "only 2 of 3 injector result files present"


def test_report_without_any_results_still_publishes_a_verdict(container):
    result = container.run(ENTRYPOINT, "report", EXPECTED_INJECTORS="2")
    assert result.returncode == 0, result.stderr
    verdict = read_report(container, "verdict.json")
    assert verdict["passed"] is False
    assert verdict["overall"]["count"] == 0
    assert container.calls("jmeter.log") == [], "no dashboard without samples"
    assert not (container.s3 / "reports" / RUN_ID / "index.html").exists()


def test_report_fails_on_an_invalid_threshold(finished_run):
    result = finished_run.run(ENTRYPOINT, "report", FAIL_IF="p95 above 800")
    assert result.returncode == 1
    assert "jtl_summary.py failed with status 2" in result.stderr
    assert not (finished_run.s3 / "reports" / RUN_ID / "verdict.json").exists()


def test_report_fails_when_the_dashboard_cannot_be_built(finished_run):
    result = finished_run.run(ENTRYPOINT, "report", FAKE_JMETER_EXIT="1")
    assert result.returncode == 1
    assert not (finished_run.s3 / "reports" / RUN_ID / "verdict.json").exists()


def test_unknown_mode_prints_usage(container):
    result = container.run(ENTRYPOINT, "explode")
    assert result.returncode == 64
    assert "usage: entrypoint.sh run|report" in result.stderr
