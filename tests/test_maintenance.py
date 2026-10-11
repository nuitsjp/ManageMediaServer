import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def function(script, name):
    text = (ROOT / 'scripts/ops' / script).read_text()
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', text, re.M | re.S)[0]


class MaintenanceTests(unittest.TestCase):
    def shell(self, code, env=None):
        return subprocess.run(['bash', '-euo', 'pipefail', '-c', code],
                              env={**os.environ, **(env or {})}, text=True,
                              capture_output=True)

    def test_child_does_not_inherit_parent_paths(self):
        code = function('media-daily-maintenance.sh', 'run_as_child_user')
        result = self.shell(code + '''
CHILD_USER=root
run_as_child_user bash -c 'test -z "${LOG_DIR+x}${LOG_FILE+x}${LOCK_FILE+x}"; test "$SUMMARY_FILE" = summary'
''', {'LOG_DIR': '/root/log', 'LOG_FILE': '/root/file',
      'LOCK_FILE': '/root/lock', 'SUMMARY_FILE': 'summary'})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_success_marker_only_for_real_success(self):
        for status, dry, check, expected in [
            ('succeeded', 'false', 'false', True),
            ('failed', 'false', 'false', False),
            ('succeeded', 'true', 'false', False),
            ('succeeded', 'false', 'true', False),
        ]:
            with self.subTest(status=status, dry=dry, check=check), tempfile.TemporaryDirectory() as temp:
                code = function('media-daily-maintenance.sh', 'on_exit')
                code += f'''
DAILY_RESULT={status}; DRY_RUN={dry}; CHECK_ONLY={check}
PREFLIGHT_ONLY=false; SUMMARY_DIR=''; REBOOT_ACTION=not_required
LAST_SUCCESS_FILE={temp}/state/last-success
schedule_reboot_if_needed() {{ :; }}
notify_discord() {{ :; }}
on_exit
'''
                outcome = self.shell(code)
                self.assertEqual(outcome.returncode, 0, outcome.stderr)
                self.assertEqual(Path(temp, 'state/last-success').exists(), expected)

    def pull(self, fail_until, retries=3):
        with tempfile.TemporaryDirectory() as temp:
            code = function('media-app-update.sh', 'run_compose_update')
            code += f'''
cd {temp}
log() {{ :; }}
sleep() {{ :; }}
docker() {{
    if [[ "$*" == *pull ]]; then
        local count=0
        [[ ! -f attempts ]] || read -r count < attempts
        count=$((count+1)); echo "$count" > attempts
        (( count > {fail_until} ))
    else
        touch started
    fi
}}
CHECK_ONLY=false; DRY_RUN=false
PULL_RETRIES={retries}; PULL_RETRY_SLEEP_SECONDS=1
run_compose_update test "$PWD"
'''
            result = self.shell(code)
            attempts = int(Path(temp, 'attempts').read_text())
            return result.returncode, attempts, Path(temp, 'started').exists()

    def test_transient_pull_recovers_before_start(self):
        self.assertEqual(self.pull(2), (0, 3, True))

    def test_exhausted_pull_does_not_start(self):
        self.assertEqual(self.pull(99), (1, 3, False))

    def monitor(self, result='success', active='inactive', success='recent', reboot='none'):
        with tempfile.TemporaryDirectory() as temp:
            success_file = Path(temp, 'success')
            reboot_file = Path(temp, 'reboot')
            import time
            now = int(time.time())
            if success != 'missing':
                success_file.write_text(str(now if success == 'recent' else now - 200000))
            if reboot != 'none':
                reboot_file.touch()
                if reboot == 'old':
                    os.utime(reboot_file, (now - 100000, now - 100000))
            code = function('media-health-check.sh', 'check_maintenance_result')
            code += '\n' + function('media-health-check.sh', 'check_pending_reboot')
            code += f'''
record_failure() {{ echo "FAIL $*"; }}
record_ok() {{ echo "OK $*"; }}
systemctl() {{ if [[ "$*" == *ActiveState* ]]; then echo {active}; else echo {result}; fi; }}
MAINTENANCE_SERVICE=maintenance
LAST_SUCCESS_FILE={success_file}
MAINTENANCE_MAX_AGE_SECONDS=172800
REBOOT_REQUIRED_FILE={reboot_file}
REBOOT_MAX_AGE_SECONDS=86400
check_maintenance_result
check_pending_reboot
'''
            outcome = self.shell(code)
            self.assertEqual(outcome.returncode, 0, outcome.stderr)
            return outcome.stdout

    def test_healthy_monitor(self):
        self.assertNotIn('FAIL', self.monitor())

    def test_failed_daily_is_detected(self):
        self.assertIn('daily maintenance failed', self.monitor('exit-code', 'failed'))

    def test_running_daily_does_not_report_previous_result_as_failure(self):
        self.assertNotIn('FAIL', self.monitor('exit-code', 'activating'))

    def test_stale_and_missing_success_are_detected(self):
        self.assertIn('last success is stale', self.monitor(success='stale'))
        self.assertIn('no recorded successful run', self.monitor(success='missing'))

    def test_reboot_grace_period_and_overdue(self):
        self.assertNotIn('FAIL', self.monitor(reboot='new'))
        self.assertIn('reboot request is overdue', self.monitor(reboot='old'))


if __name__ == '__main__':
    unittest.main()
