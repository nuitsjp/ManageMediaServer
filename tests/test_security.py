"""Security regressions using temporary files; no sudo, services or network."""
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
OPS = ROOT / 'scripts/ops'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


READER = module('summary_reader', OPS / 'read-maintenance-summary.py')
CONFIG = module('maintenance_config', OPS / 'prepare-maintenance-config.py')


def function(script, name):
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', script.read_text(), re.M | re.S)[0]


class SecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.result_file = self.directory / 'summary.json'

    def read_result(self, content=None, step='media-backup'):
        if content is not None:
            self.result_file.write_bytes(content if isinstance(content, bytes) else json.dumps(content).encode())
        return subprocess.run(['python3', '-B', str(OPS / 'read-maintenance-summary.py'), step,
                               str(self.result_file)], capture_output=True, timeout=3)

    def assert_rejected(self, content=None, step='media-backup'):
        result = self.read_result(content, step)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, b'')
        self.assertEqual(result.stderr, b'Invalid or missing maintenance result\n')

    def test_shell_summary_is_never_executed(self):
        marker = self.directory / 'executed'
        self.assert_rejected(f'MEDIA_BACKUP_STATUS=succeeded\ntouch {marker}\n'.encode())
        self.assertFalse(marker.exists())

    def test_cross_step_and_control_variables_are_rejected(self):
        for field in ('PATH', 'BASH_ENV', 'CHILD_USER', 'MEDIA_OS_REBOOT_REQUIRED', 'SUMMARY_DIR',
                      'MEDIA_BACKUP_STATUS[0]', 'read_step_summary'):
            with self.subTest(field=field):
                self.assert_rejected({'MEDIA_BACKUP_STATUS': 'succeeded', field: 'malicious'})

    def test_invalid_shapes_values_duplicates_and_statuses_are_rejected(self):
        for content in ([], {}, {'MEDIA_BACKUP_STATUS': 1}, {'MEDIA_BACKUP_STATUS': 'unknown'},
                        {'MEDIA_BACKUP_STATUS': 'succeeded', 'MEDIA_BACKUP_MESSAGE': ['bad']},
                        {'MEDIA_BACKUP_STATUS': 'succeeded', 'MEDIA_BACKUP_MESSAGE': 'bad\0data'},
                        {'MEDIA_BACKUP_STATUS': 'succeeded', 'MEDIA_BACKUP_MESSAGE': '\ud800'},
                        b'{"MEDIA_BACKUP_STATUS":"succeeded","MEDIA_BACKUP_STATUS":"failed"}',
                        b'[' * 2000):
            with self.subTest(content=repr(content)[:80]):
                self.assert_rejected(content)

    def test_oversized_missing_symlink_and_fifo_results_are_rejected(self):
        self.assert_rejected(b'x' * (READER.MAX_BYTES + 1))
        self.result_file.unlink()
        self.assert_rejected()
        target = self.directory / 'target'
        target.write_text('{"MEDIA_BACKUP_STATUS":"succeeded"}')
        self.result_file.symlink_to(target)
        self.assert_rejected()
        self.result_file.unlink()
        os.mkfifo(self.result_file)
        self.assert_rejected()

    def test_literal_data_survives_bash_assignment_without_execution(self):
        marker = self.directory / 'executed'
        message = f"$(touch {marker}) `touch {marker}` 'quotes' \\ spaces\n日本語\n"
        self.result_file.write_text(json.dumps({'MEDIA_BACKUP_STATUS': 'succeeded', 'MEDIA_BACKUP_MESSAGE': message}))
        code = function(OPS / 'media-daily-maintenance.sh', 'read_step_summary')
        code += f'''
SCRIPT_DIR={shlex.quote(str(OPS))}
SUMMARY_DIR={shlex.quote(str(self.directory))}
CURRENT_STEP=backup; MEDIA_OS_REBOOT_REQUIRED=no
mark_failed() {{ echo failed; }}
read_step_summary {shlex.quote(str(self.result_file))} media-backup MEDIA_BACKUP_STATUS
printf '%s' "$MEDIA_BACKUP_MESSAGE"
test "$MEDIA_OS_REBOOT_REQUIRED" = no
'''
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', code], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode(), message)
        self.assertFalse(marker.exists())
        self.assertFalse(list(self.directory.glob('.validated.*')))

    def test_private_result_directories(self):
        code = function(OPS / 'media-daily-maintenance.sh', 'initialize_summary_dir')
        code += '\nCHILD_USER=$(id -un); initialize_summary_dir; printf %s "$SUMMARY_DIR"\n'
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', code], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        directory = Path(result.stdout)
        try:
            for path in (directory, directory / 'child', directory / 'root'):
                self.assertEqual(path.stat().st_mode & 0o777, 0o700)
        finally:
            (directory / 'child').rmdir()
            (directory / 'root').rmdir()
            directory.rmdir()

    def test_validation_storage_failure_marks_backup_failed(self):
        code = function(OPS / 'media-daily-maintenance.sh', 'read_step_summary')
        code += '''
SUMMARY_DIR=$MISSING; SCRIPT_DIR=$OPS; CURRENT_STEP=backup
MEDIA_BACKUP_STATUS=succeeded; MEDIA_BACKUP_FAILED=false; FAILURE_RECORDED=false
mark_failed() { FAILURE_RECORDED=true; }
if read_step_summary /unused media-backup MEDIA_BACKUP_STATUS; then exit 1; fi
test "$MEDIA_BACKUP_STATUS" = failed
test "$MEDIA_BACKUP_FAILED" = true
test "$FAILURE_RECORDED" = true
'''
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', code], capture_output=True,
                                env={**os.environ, 'MISSING': str(self.directory / 'missing'), 'OPS': str(OPS)})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_all_actual_summary_writers_produce_accepted_json(self):
        variables = '''
SUMMARY_FILE=$OUTPUT; DRY_RUN=false; CHECK_ONLY=false; LOG_FILE='/log with spaces'
COPIED_TARGETS=('a b'); UPDATED_CONTAINERS=('test'); MAJOR_UPDATE_MESSAGES=()
LATEST_VERSION_SUMMARY=('日本語'); NO_DELETE=false
IMAGE_COPY_STATUS=succeeded; VIDEO_COPY_STATUS=succeeded; BACKUP_STATUS=succeeded
VERIFIED_COUNT=1; DELETED_COUNT=0; SKIPPED_VIDEO_COUNT=0; VERIFIED_FILE=''; DRY_RUN_LOG=''
APT_UPGRADED_PACKAGES=none; APT_UPGRADED_COUNT=0; SNAP_REFRESHED_PACKAGES=none
SNAP_REFRESHED_COUNT=0; AUTOREMOVE_STATUS=disabled; REBOOT_REQUIRED=no; REBOOT_REQUIRED_PACKAGES=none
UPDATE_STATUS=update_available; CURRENT_VERSION=v0.1.0; LATEST_VERSION=v0.1.1; UPDATED_VERSION=none
join_items() { local separator=$1; shift; printf '%s' "${1:-}"; }
'''
        for script, step in [('media-backup.sh', 'media-backup'), ('media-app-update.sh', 'media-app-update'),
                             ('rclone-media-sync.sh', 'rclone-media-sync'), ('media-os-update.sh', 'os-update'),
                             ('../../token-monitor/scripts/update.sh', 'token-monitor-update')]:
            with self.subTest(step=step):
                code = function(OPS / script, 'write_summary') + variables + '\nwrite_summary succeeded "test message"\n'
                result = subprocess.run(['bash', '-euo', 'pipefail', '-c', code],
                                        env={**os.environ, 'OUTPUT': str(self.result_file)}, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                parsed = self.read_result(step=step)
                self.assertEqual(parsed.returncode, 0, parsed.stderr)
        code = function(ROOT / 'token-monitor-analytics/scripts/update.sh', 'finish')
        code += '''
CANDIDATE_PID=''; STOPPED=false; OLD_RELEASE=''; CREATED_RELEASE=''; TEMP=''
STATUS=current; CURRENT_VERSION=v0.1.0; VERSION=v0.1.0; SUMMARY_FILE=$OUTPUT
finish
'''
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', code],
                                env={**os.environ, 'OUTPUT': str(self.result_file)}, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_result(step='analytics-update').returncode, 0)

    def test_root_configuration_rejects_user_files_and_symlinks(self):
        code = function(OPS / 'media-daily-maintenance.sh', 'assert_root_owned_path')
        self.result_file.write_text('unsafe')
        link = self.directory / 'link'
        link.symlink_to('/usr/bin/bash')
        for path, accepted in [(self.result_file, False), (link, False), (Path('/usr/bin/bash'), True)]:
            result = subprocess.run(['bash', '-euo', 'pipefail', '-c', code + '\nassert_root_owned_path "$1"',
                                     'test', str(path)], capture_output=True)
            self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_config_migration_keeps_credentials_literal(self):
        source = self.directory / 'source'; source.mkdir()
        destination = self.directory / 'protected'; destination.mkdir()
        marker = self.directory / 'executed'
        value = f'https://example.invalid/$(touch {marker})#credential'
        (source / 'notification.env').write_text(f'NOTIFICATION_ENABLED=true\nDISCORD_WEBHOOK_URL={shlex.quote(value)}\n')
        CONFIG.prepare(source, destination)
        result = subprocess.run(['bash', '-c', 'source "$1"; printf %s "$DISCORD_WEBHOOK_URL"',
                                 'test', str(destination / 'notification.env')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, value)
        self.assertFalse(marker.exists())
        for file in destination.iterdir():
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        values = CONFIG.parse_env((destination / 'media-daily-maintenance.env').read_text(), 'media-daily-maintenance.env')
        self.assertEqual(values['CHILD_USER'], 'mediaserver')
        self.assertTrue(values['MEDIA_OS_UPDATE_SCRIPT'].startswith('/usr/local/libexec/'))

    def test_config_migration_rejects_environment_and_arithmetic_injection(self):
        for name, text in [('notification.env', 'BASH_ENV=/tmp/evil'),
                           ('notification.env', 'NOTIFICATION_ENABLED=maybe'),
                           ('media-daily-maintenance.env', "AUTO_REBOOT_DELAY_MINUTES='a[$(touch /tmp/evil)]'"),
                           ('media-os-update.env', "ROOT_MIN_FREE_KIB='a[$(touch /tmp/evil)]'"),
                           ('media-os-update.env', "APT_UPGRADE_COMMAND='-o APT::Update::Pre-Invoke=evil'"),
                           ('notification.env', 'touch /tmp/evil')]:
            with self.subTest(name=name, text=text), self.assertRaises(ValueError):
                CONFIG.parse_env(text, name)


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        directory = Path(self.temp.name)
        updater = directory / 'update.sh'
        updater.write_text('''printf 'executed\n'
test -z "${UNTRUSTED_VALUE+x}"
test "$PATH" = /usr/sbin:/usr/bin:/sbin:/bin
test "$HOME" = /root
printf '%s\n' "$@"
''')
        text = (ROOT / 'token-monitor-analytics/scripts/manual-update.sh').read_text()
        text = text.replace('/usr/local/libexec/token-monitor-analytics/update.sh', shlex.quote(str(updater)))
        self.wrapper = directory / 'wrapper.sh'
        self.wrapper.write_text(text)

    def run_wrapper(self, args):
        return subprocess.run(['sh', str(self.wrapper), *args],
                              env={**os.environ, 'UNTRUSTED_VALUE': 'must be cleared'}, capture_output=True, text=True)

    def test_local_packages_unknown_options_and_help_bypass_are_rejected(self):
        for args in [['--archive', '/tmp/archive'], ['--sha256-file', '/tmp/checksum'],
                     ['--help', '--archive', '/tmp/archive'], ['--version'], ['--version', ''],
                     ['--version', 'v1.2.3', '--archive', '/tmp/archive'], ['--', '--archive', '/tmp/archive']]:
            with self.subTest(args=args):
                result = self.run_wrapper(args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn('executed', result.stdout)

    def test_release_options_forward_exact_arguments_with_clean_environment(self):
        for args in [[], ['--version', 'v1.2.3'], ['--check-only'], ['--dry-run'],
                     ['--version', 'v1.2.3', '--check-only']]:
            with self.subTest(args=args):
                result = self.run_wrapper(args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), ['executed', *args] if args else ['executed', ''])

    def test_help_describes_only_release_options(self):
        result = self.run_wrapper(['--help'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('--archive', result.stdout)
        self.assertNotIn('executed', result.stdout)


@unittest.skipIf(os.geteuid() == 0, 'Workflow fixture runs as an unprivileged user')
class WorkflowTests(unittest.TestCase):
    def workflow(self, backup):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            token = directory / 'token-monitor/scripts'; token.mkdir(parents=True)
            scripts = {}
            for step, status in [('backup', 'MEDIA_BACKUP_STATUS'), ('app', 'MEDIA_APP_UPDATE_STATUS'),
                                 ('token', 'TOKEN_MONITOR_UPDATE_STATUS'), ('sync', 'RCLONE_SYNC_STATUS')]:
                file = token / 'update.sh' if step == 'token' else directory / f'{step}.sh'
                content = backup if step == 'backup' else {status: 'succeeded'}
                file.write_text('set -euo pipefail\necho called > "$CALL_DIR/' + step + '"\nprintf %s ' +
                                shlex.quote(content if isinstance(content, str) else json.dumps(content)) + ' > "$SUMMARY_FILE"\n')
                scripts[step] = file
            for name in ('backup-data.sh', 'build-image.sh', 'healthcheck.sh'):
                (token / name).touch()
            for path in (directory / 'token-monitor/compose.yaml', directory / 'token-monitor/Dockerfile'):
                path.touch()
            (directory / 'config/env').mkdir(parents=True)
            for name in ('token-monitor-deploy.env', 'token-monitor-common.env'):
                (directory / 'config/env' / name).touch()
            env_file = directory / 'daily.env'
            settings = {
                'PROD_ROOT': str(directory), 'LOG_DIR': str(directory / 'logs'),
                'LOCK_FILE': str(directory / 'daily.lock'), 'LAST_SUCCESS_FILE': str(directory / 'last-success'),
                'CHILD_USER': pwd.getpwuid(os.getuid()).pw_name,
                'MEDIA_BACKUP_SCRIPT': str(scripts['backup']), 'MEDIA_APP_UPDATE_SCRIPT': str(scripts['app']),
                'TOKEN_MONITOR_UPDATE_SCRIPT': str(scripts['token']), 'RCLONE_MEDIA_SYNC_SCRIPT': str(scripts['sync']),
                'RUN_OS_UPDATE': 'false', 'RUN_ANALYTICS_UPDATE': 'false', 'AUTO_REBOOT': 'false',
            }
            env_file.write_text(''.join(f'{key}={shlex.quote(value)}\n' for key, value in settings.items()))
            notify = directory / 'notification.env'; notify.write_text('NOTIFICATION_ENABLED=false\n')
            result = subprocess.run(['bash', str(OPS / 'media-daily-maintenance.sh')], capture_output=True, text=True,
                                    env={**os.environ, 'MEDIA_DAILY_ENV': str(env_file), 'NOTIFICATION_ENV': str(notify),
                                         'CALL_DIR': str(directory)}, timeout=10)
            return result, {step for step in scripts if (directory / step).exists()}, (directory / 'last-success').exists()

    def test_valid_results_complete_workflow_and_record_success(self):
        result, calls, success = self.workflow({'MEDIA_BACKUP_STATUS': 'succeeded'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, {'backup', 'app', 'token', 'sync'})
        self.assertTrue(success)

    def test_invalid_or_failed_backup_blocks_app_update_and_success_record(self):
        for backup in ['MEDIA_BACKUP_STATUS=succeeded', {'MEDIA_BACKUP_STATUS': 'failed'},
                       {'MEDIA_BACKUP_STATUS': 'succeeded', 'RUN_OS_UPDATE': 'true'}]:
            with self.subTest(backup=backup):
                result, calls, success = self.workflow(backup)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(calls, {'backup', 'token', 'sync'})
                self.assertFalse(success)
                self.assertIn('skipping media app update', result.stdout)


if __name__ == '__main__':
    unittest.main()
