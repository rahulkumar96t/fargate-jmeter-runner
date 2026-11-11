import os
import sys
from pathlib import Path

import pytest
from support import BUCKET, FAKES, Sandbox


@pytest.fixture
def sandbox(tmp_path: Path) -> Sandbox:
    (tmp_path / "s3" / BUCKET).mkdir(parents=True)
    # The fakes are Python scripts; put this interpreter first on PATH for them.
    path = os.pathsep.join([str(FAKES), str(Path(sys.executable).parent), os.environ.get("PATH", "")])
    env = {
        "PATH": path,
        "HOME": str(tmp_path),
        "FAKE_S3_ROOT": str(tmp_path / "s3"),
        "FAKE_AWS_LOG": str(tmp_path / "aws.log"),
        "FAKE_JMETER_LOG": str(tmp_path / "jmeter.log"),
    }
    return Sandbox(root=tmp_path, env=env)
