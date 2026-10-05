"""Regression checks without Docker, privileged access, or network calls."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "scripts"


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.scripts = self.root / "scripts"
        shutil.copytree(SOURCE, self.scripts)
        self.env = os.environ | {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "TOKEN_MONITOR_DEPLOY_ENV": str(self.root / "deploy.env"),
            "TOKEN_MONITOR_COMMON_ENV": str(self.root / "common.env"),
            "TOKEN_MONITOR_LOG_DIR": str(self.root / "logs"),
            "TOKEN_MONITOR_DATA_ROOT": str(self.root / "data"),
            "TOKEN_MONITOR_BACKUP_ROOT": str(self.root / "backup"),
            "CALLS": str(self.root / "calls"),
            "MOCK_STATE": "matched",
        }
        (self.root / "deploy.env").write_text("TOKEN_MONITOR_VERSION=v0.66.0\n")
        (self.root / "common.env").write_text("")
        self.mock("curl", 'echo \'{"draft":false,"prerelease":false,"tag_name":"v0.66.0"}\'')
        self.mock("mountpoint", "exit 0")
        self.mock("docker", '''
echo "$*" >> "$CALLS"
case "$1 $2" in
  "image inspect") echo sha256:expected ;;
  "inspect -f")
    if [[ "$3" == *State.Running* && "$3" != *Image* ]]; then echo true
    elif [[ "$MOCK_STATE" == missing ]]; then exit 1
    elif [[ "$MOCK_STATE" == drift && "$4" == token-monitor-hub-work ]]; then echo 'sha256:old true'
    elif [[ "$MOCK_STATE" == stopped ]]; then echo 'sha256:expected false'
    else echo 'sha256:expected true'; fi ;;
  "cp "*) [[ "${FAIL_COPY:-}" != yes ]] ;;
esac
''')
        (self.scripts / "healthcheck.sh").write_text(
            '#!/bin/bash\n[[ "${MOCK_STATE:-}" != unhealthy ]]\n'
        )

    def mock(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + body + "\n")
        path.chmod(0o755)

    def run_script(self, name, *args):
        return subprocess.run(
            ["bash", str(self.scripts / name), *args], env=self.env,
            text=True, capture_output=True,
        )

    def test_equal_version_checks_all_running_images(self):
        result = self.run_script("update.sh", "--check-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already current", result.stdout)
        calls = (self.root / "calls").read_text()
        for name in ["hub-work", "hub-private", "agent-private"]:
            self.assertIn(f"token-monitor-{name}", calls)

    def test_equal_version_requires_repair_on_drift_missing_stopped_or_unhealthy(self):
        for state in ["drift", "missing", "stopped", "unhealthy"]:
            with self.subTest(state=state):
                self.env["MOCK_STATE"] = state
                result = self.run_script("update.sh", "--check-only")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("update available", result.stdout)
                self.assertNotIn("already current", result.stdout)

    def test_agent_backup_uses_docker_copy_and_restarts(self):
        (self.root / "data/agent-private/state").mkdir(parents=True)
        result = self.run_script("backup-data.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertIn("stop token-monitor-agent-private", calls)
        self.assertIn("cp token-monitor-agent-private:/var/lib/token-monitor/.", calls)
        self.assertIn("start token-monitor-agent-private", calls)
        self.assertTrue((self.root / "backup/latest-backup.txt").exists())

    def test_failed_backup_restarts_agent_without_marking_complete(self):
        (self.root / "data/agent-private/state").mkdir(parents=True)
        self.env["FAIL_COPY"] = "yes"
        result = self.run_script("backup-data.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("start token-monitor-agent-private", (self.root / "calls").read_text())
        self.assertFalse((self.root / "backup/latest-backup.txt").exists())


if __name__ == "__main__":
    unittest.main()
