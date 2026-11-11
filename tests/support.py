"""Helpers for the shell-script tests.

The scripts run for real (bash), with ``aws`` and ``jmeter`` replaced by the small
fakes in tests/fakes: S3 is a directory tree, JMeter copies a fixture JTL.
"""

import json
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAKES = ROOT / "tests" / "fakes"
FIXTURES = ROOT / "tests" / "fixtures"
BUCKET = "results"


@dataclass
class Sandbox:
    root: Path
    env: dict[str, str] = field(default_factory=dict)

    @property
    def s3(self) -> Path:
        return self.root / "s3" / BUCKET

    def put(self, key: str, source: Path | str) -> Path:
        target = self.s3 / key
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(source, Path):
            shutil.copyfile(source, target)
        else:
            target.write_text(source)
        return target

    def calls(self, log_name: str) -> list[list[str]]:
        log = self.root / log_name
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text().splitlines()]

    def run(self, script: Path, *args: str, **env: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["bash", str(script), *args],
            env={**self.env, **env},
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
