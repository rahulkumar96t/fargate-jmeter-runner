import json

import pytest
from support import ROOT

SCRIPT = ROOT / "scripts" / "run-test.sh"
STATE_MACHINE = "arn:aws:states:eu-central-1:111111111111:stateMachine:jmeter-load-test"
REQUIRED = ("-p", "plans/smoke/smoke.jmx", "-t", "perf.example.com")


def dry_run(sandbox, *args):
    result = sandbox.run(SCRIPT, *REQUIRED, *args, "--dry-run")
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def test_dry_run_prints_the_execution_input(sandbox):
    document = dry_run(
        sandbox,
        *("-n", "4", "-s", "L", "-u", "200", "-r", "120", "-d", "900"),
        *("-f", "p95>800", "-f", "errors>1%", "-J", "think.ms=250"),
    )
    assert document == {
        "plan": "plans/smoke/smoke.jmx",
        "targetHost": "perf.example.com",
        "injectors": 4,
        "size": "L",
        "threads": 200,
        "rampUpSeconds": 120,
        "durationSeconds": 900,
        "targetProtocol": "https",
        "targetPort": 443,
        "thresholds": "p95>800,errors>1%",
        "properties": "think.ms=250",
    }


def test_omitted_thresholds_leave_the_module_default_in_charge(sandbox):
    document = dry_run(sandbox)
    assert "thresholds" not in document
    assert "properties" not in document


def test_target_is_lowercased_and_numbers_are_decimal(sandbox):
    document = dry_run(sandbox, "-t", "PERF.Example.COM", "-u", "08")
    assert document["targetHost"] == "perf.example.com"
    assert document["threads"] == 8


@pytest.mark.parametrize(
    ("args", "message"),
    [
        (("-s", "XXL"), "--size must be S, M, L or XL"),
        (("-n", "0"), "--injectors must be at least 1"),
        (("-n", "two"), "--injectors must be a whole number"),
        (("-r", "600", "-d", "300"), "--ramp-up cannot be longer than --duration"),
        (("-t", "https://perf.example.com/"), "--target must be a host name"),
        (("-p", "plans/../x.jmx"), "--plan must look like plans/"),
        (("-f", "p95 > 800"), "invalid --fail-if"),
        (("-J", "bad value"), "invalid -J"),
        (("--name", "has/slash"), "--name may contain"),
        (("--protocol", "ftp"), "--protocol must be http or https"),
        (("--port", "70000"), "--port must be between 1 and 65535"),
        (("--bogus",), "unknown option: --bogus"),
    ],
)
def test_invalid_arguments_exit_2_before_calling_aws(sandbox, args, message):
    result = sandbox.run(SCRIPT, *REQUIRED, *args, "--dry-run")
    assert result.returncode == 2
    assert message in result.stderr
    assert sandbox.calls("aws.log") == []


def test_start_requires_a_state_machine(sandbox):
    result = sandbox.run(SCRIPT, *REQUIRED)
    assert result.returncode == 2
    assert "JMETER_STATE_MACHINE_ARN" in result.stderr


def test_starts_an_execution_named_after_the_run(sandbox):
    result = sandbox.run(SCRIPT, *REQUIRED, "--name", "smoke-1", JMETER_STATE_MACHINE_ARN=STATE_MACHINE)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip().endswith(":execution:jmeter-load-test:smoke-1")

    [call] = sandbox.calls("aws.log")
    assert call[:2] == ["stepfunctions", "start-execution"]
    assert call[call.index("--state-machine-arn") + 1] == STATE_MACHINE
    assert call[call.index("--name") + 1] == "smoke-1"
    assert json.loads(call[call.index("--input") + 1])["targetHost"] == "perf.example.com"


def test_default_run_name_is_derived_from_the_plan(sandbox):
    result = sandbox.run(SCRIPT, *REQUIRED, JMETER_STATE_MACHINE_ARN=STATE_MACHINE)
    assert result.returncode == 0, result.stderr
    [call] = sandbox.calls("aws.log")
    name = call[call.index("--name") + 1]
    assert name.startswith("smoke-") and name.endswith("Z")


def test_upload_puts_the_plan_in_place_first(sandbox, tmp_path):
    plan = tmp_path / "local.jmx"
    plan.write_text("<jmeterTestPlan/>")
    result = sandbox.run(
        SCRIPT,
        *REQUIRED,
        *("--upload", str(plan), "-b", "results"),
        JMETER_STATE_MACHINE_ARN=STATE_MACHINE,
    )
    assert result.returncode == 0, result.stderr
    assert (sandbox.s3 / "plans" / "smoke" / "smoke.jmx").read_text() == "<jmeterTestPlan/>"
    assert [c[:2] for c in sandbox.calls("aws.log")] == [["s3", "cp"], ["stepfunctions", "start-execution"]]


def test_wait_returns_0_when_the_run_succeeds(sandbox):
    result = sandbox.run(
        SCRIPT,
        *REQUIRED,
        "--wait",
        "-b",
        "results",
        "--name",
        "ok-run",
        JMETER_STATE_MACHINE_ARN=STATE_MACHINE,
    )
    assert result.returncode == 0, result.stderr
    assert "finished: SUCCEEDED" in result.stderr
    assert "s3://results/reports/ok-run/index.html" in result.stderr


def test_wait_returns_1_and_shows_the_error_when_the_run_fails(sandbox):
    result = sandbox.run(
        SCRIPT,
        *REQUIRED,
        "--wait",
        JMETER_STATE_MACHINE_ARN=STATE_MACHINE,
        FAKE_SFN_STATUS="FAILED",
        FAKE_SFN_ERROR="VerdictFailed\tp95>800 breached (actual 912)",
    )
    assert result.returncode == 1
    assert "finished: FAILED" in result.stderr
    assert "p95>800 breached" in result.stderr
