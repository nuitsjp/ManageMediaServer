"""Upgrade data checks and rollback ordering without Docker or privileged access."""
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'scripts/ops/upgrade-jellyfin.sh'
spec = importlib.util.spec_from_file_location('jellyfin_upgrade', ROOT / 'scripts/ops/jellyfin-upgrade.py')
UPGRADE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(UPGRADE)


def function(name):
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)[0]


class DataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.config = self.directory / 'config'
        (self.config / 'data').mkdir(parents=True)
        (self.config / 'config').mkdir()
        self.state = self.directory / 'scan-state.json'
        self.db = self.config / 'data/jellyfin.db'
        with sqlite3.connect(self.db) as db:
            db.executescript('''
CREATE TABLE Users (Id TEXT, Password TEXT);
INSERT INTO Users VALUES ('user', 'private-password-hash');
CREATE TABLE BaseItems (Id TEXT, IsFolder INTEGER, MediaType TEXT, Path TEXT);
INSERT INTO BaseItems VALUES ('a', 0, 'Video', '/media/music-videos/a.mp4');
INSERT INTO BaseItems VALUES ('b', 0, 'Video', '/media/music-videos/b.mp4');
CREATE TABLE UserData (ItemId TEXT, UserId TEXT, PlayCount INTEGER, Played INTEGER,
                      IsFavorite INTEGER, PlaybackPositionTicks INTEGER);
INSERT INTO UserData VALUES ('a','user',3,1,0,100);
''')
        self.system = self.config / 'config/system.xml'
        self.system.write_text('''<ServerConfiguration><IsStartupWizardCompleted>true</IsStartupWizardCompleted>
<PluginRepositories>
<RepositoryInfo><Name>Official</Name><Url>https://repo.jellyfin.org/releases/plugin/manifest-stable.json</Url></RepositoryInfo>
<RepositoryInfo><Name>Custom</Name><Url>https://example.invalid/custom.json</Url></RepositoryInfo>
</PluginRepositories></ServerConfiguration>''')

    def sql(self, statement):
        with sqlite3.connect(self.db) as db:
            db.execute(statement)

    def test_snapshot_is_private_and_preserves_all_existing_data(self):
        before = UPGRADE.snapshot(self.config)
        self.assertEqual(len(before['users']), 1)
        self.assertEqual(len(before['media']), 2)
        self.assertEqual(len(before['progress']), 1)
        self.assertNotIn('private-password-hash', json.dumps(before))
        self.assertNotIn('/media/', json.dumps(before))
        self.sql("INSERT INTO BaseItems VALUES ('c',0,'Video','/media/music-videos/c.mp4')")
        UPGRADE.verify_snapshot(before, UPGRADE.snapshot(self.config))

    def test_account_media_or_progress_loss_is_rejected(self):
        before = UPGRADE.snapshot(self.config)
        for sql in ["UPDATE Users SET Password='changed'", 'DELETE FROM BaseItems WHERE Id=\'b\'', 'DELETE FROM UserData']:
            with self.subTest(sql=sql):
                db_copy = self.db.read_bytes()
                self.sql(sql)
                with self.assertRaises(ValueError):
                    UPGRADE.verify_snapshot(before, UPGRADE.snapshot(self.config))
                self.db.write_bytes(db_copy)

    def test_corrupt_database_is_rejected(self):
        self.db.write_bytes(b'not a database')
        with self.assertRaises((sqlite3.Error, ValueError)):
            UPGRADE.snapshot(self.config)

    def test_scan_task_id_matches_existing_jellyfin_history(self):
        self.assertEqual(UPGRADE.TASK_ID, '7738148f-fcd0-7979-c7ce-b148e06b3aed')

    def test_one_time_scan_preserves_default_schedule_and_restores_absence(self):
        UPGRADE.prepare_scan(self.config, self.state)
        path = self.config / 'config/ScheduledTasks' / UPGRADE.SCAN_FILE
        triggers = json.loads(path.read_text())
        self.assertEqual(triggers, [{'Type':'IntervalTrigger','IntervalTicks':432000000000}, {'Type':'StartupTrigger'}])
        repos = ET.parse(self.system).getroot().findall('./PluginRepositories/*/Url')
        self.assertEqual(repos[0].text, UPGRADE.PLUGIN_URL)
        self.assertEqual(repos[1].text, 'https://example.invalid/custom.json')
        self.assertEqual(ET.parse(self.system).getroot().findtext('IsStartupWizardCompleted'), 'true')
        UPGRADE.restore_scan(self.config, self.state)
        self.assertFalse(path.exists())

    def test_custom_schedule_bytes_permissions_and_existing_startup_are_preserved(self):
        path = self.config / 'config/ScheduledTasks' / UPGRADE.SCAN_FILE
        path.parent.mkdir()
        original = b'[ {"Type":"DailyTrigger","TimeOfDayTicks":100}, {"Type":"StartupTrigger"} ]\n'
        path.write_bytes(original); path.chmod(0o600)
        UPGRADE.prepare_scan(self.config, self.state)
        self.assertEqual(len(json.loads(path.read_text())), 2)
        UPGRADE.restore_scan(self.config, self.state)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_symlink_scan_configuration_is_rejected(self):
        path = self.config / 'config/ScheduledTasks' / UPGRADE.SCAN_FILE
        path.parent.mkdir()
        target = self.directory / 'target'; target.write_text('[]')
        path.symlink_to(target)
        with self.assertRaises(ValueError):
            UPGRADE.prepare_scan(self.config, self.state)
        self.assertEqual(target.read_text(), '[]')

    def test_only_fresh_completed_full_scan_is_accepted(self):
        folder = self.config / 'data/ScheduledTasks'; folder.mkdir()
        path = folder / UPGRADE.SCAN_FILE
        since = datetime(2026,10,12,20,tzinfo=timezone.utc).timestamp()
        result = {'StartTimeUtc':'2026-10-12T19:00:00Z','EndTimeUtc':'2026-10-12T19:00:01Z',
                  'Key':'RefreshLibrary','Status':'Completed'}
        path.write_text(json.dumps(result))
        self.assertFalse(UPGRADE.scan_result(self.config, since))
        result['StartTimeUtc']='2026-10-12T20:00:00.1234567Z'
        path.write_text(json.dumps(result))
        self.assertTrue(UPGRADE.scan_result(self.config, since))
        result['Status']='Failed'; path.write_text(json.dumps(result))
        with self.assertRaises(ValueError):
            UPGRADE.scan_result(self.config, since)
        result['Status']='Completed'; result['Key']='OtherTask'; path.write_text(json.dumps(result))
        self.assertFalse(UPGRADE.scan_result(self.config, since))

    def test_partial_history_is_retried_and_timeout_fails(self):
        folder = self.config / 'data/ScheduledTasks'; folder.mkdir()
        (folder / UPGRADE.SCAN_FILE).write_text('{')
        self.assertFalse(UPGRADE.scan_result(self.config, 0))
        with self.assertRaises(ValueError):
            UPGRADE.wait_scan(self.config, 0, 0)

    def test_history_from_earlier_in_the_same_second_is_stale(self):
        folder=self.config/'data/ScheduledTasks'; folder.mkdir()
        result={'StartTimeUtc':'2026-10-12T20:00:00.1Z','EndTimeUtc':'2026-10-12T20:00:00.2Z',
                'Key':'RefreshLibrary','Status':'Completed'}
        (folder/UPGRADE.SCAN_FILE).write_text(json.dumps(result))
        since=datetime(2026,10,12,20,tzinfo=timezone.utc).timestamp()+0.8
        self.assertFalse(UPGRADE.scan_result(self.config,since))

    def test_cli_errors_do_not_expose_authentication_or_library_data(self):
        baseline = self.directory / 'baseline.json'
        baseline.write_text(json.dumps(UPGRADE.snapshot(self.config)))
        self.sql("UPDATE Users SET Password='another-private-hash'")
        result = subprocess.run(['python3','-B',str(ROOT/'scripts/ops/jellyfin-upgrade.py'),'verify',str(baseline),str(self.config)],
                                capture_output=True,text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, '')
        self.assertNotIn('private', result.stderr)
        self.assertNotIn('/media/', result.stderr)


class RollbackTests(unittest.TestCase):
    def rollback(self, changed=True, ready=True, missing_config=False):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); backup = root/'backup'; backup.mkdir()
            temp = root/'temp'; temp.mkdir()
            config = root/'config'; config.mkdir()
            cache = root/'cache'; cache.mkdir()
            (config/'db').write_text('migrated' if changed else 'original')
            if missing_config:
                (config/'db').unlink(); config.rmdir()
            (cache/'data').write_text('new-cache')
            (backup/'config').mkdir(); (backup/'config/db').write_text('original')
            (backup/'cache').mkdir(); (backup/'cache/data').write_text('original-cache')
            deployed = root/'compose.yml'; deployed.write_text('image: new')
            saved = Path(str(backup)+str(deployed)); saved.parent.mkdir(parents=True); saved.write_text('image: old')
            code = function('restore_files') + '\n' + function('rollback') + '''
docker() { echo "docker $*" >> "$CALLS"; }
compose() { test "$(cat "$CONFIG/db")" = original; echo "compose $*" >> "$CALLS"; }
wait_ready() { test "$(cat "$CONFIG/db")" = original; echo "ready $*" >> "$CALLS"; }
FILES=("$DEPLOYED")
STOPPED=true; OLD_VERSION=10.11.11; ROLLBACK_IMAGE=old-image
rollback
'''
            result = subprocess.run(['bash','-euo','pipefail','-c',code],capture_output=True,text=True,
                                    env={**os.environ, 'BACKUP':str(backup), 'TEMP':str(temp), 'CONFIG':str(config), 'CACHE':str(cache),
                                         'CONFIG_CHANGED':str(changed).lower(), 'BACKUP_READY':str(ready).lower(),
                                         'FILES_CHANGED':str(changed).lower(), 'DEPLOYED':str(deployed), 'CALLS':str(root/'calls')})
            return result, (root/'calls').read_text(), (config/'db').read_text(), deployed.read_text(), (backup/'failed-config/db').read_text() if (backup/'failed-config/db').exists() else None

    def test_migrated_database_is_restored_before_old_image_starts(self):
        result, calls, data, compose, failed = self.rollback()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data, 'original')
        self.assertEqual(compose, 'image: old')
        self.assertEqual(failed, 'migrated')
        self.assertIn('docker stop -t 60 jellyfin', calls)
        self.assertIn('--pull never --force-recreate', calls)
        self.assertNotIn('docker start jellyfin', calls)

    def test_candidate_failure_restarts_untouched_original_container(self):
        result, calls, data, compose, failed = self.rollback(changed=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('docker start jellyfin', calls)
        self.assertNotIn('compose', calls)
        self.assertEqual(data, 'original')
        self.assertIsNone(failed)

    def test_missing_cold_backup_never_starts_old_image_on_migrated_data(self):
        result, calls, data, compose, failed = self.rollback(ready=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('compose', calls)
        self.assertNotIn('docker start', calls)
        self.assertEqual(data, 'migrated')

    def test_failed_copy_after_moving_original_config_can_be_restored(self):
        result,calls,data,compose,failed=self.rollback(missing_config=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(data,'original')
        self.assertEqual(compose,'image: old')
        self.assertIsNone(failed)


class PolicyTests(unittest.TestCase):
    def shell(self, code):
        return subprocess.run(['bash','-euo','pipefail','-c',code],capture_output=True,text=True)

    def test_readiness_accepts_assembly_version_but_rejects_other_release_or_fresh_setup(self):
        for version, configured, expected in [('12.2.0',True,True),('12.2',True,True),('12.1.0',True,False),('12.2.0',False,False)]:
            with self.subTest(version=version, configured=configured):
                info=json.dumps({'Version':version,'StartupWizardCompleted':configured,'ServerName':'private-server-name'})
                code=function('wait_ready') + f'''
sleep() {{ :; }}
docker() {{
    if [[ "$1" == exec ]]; then printf '%s' {shlex.quote(info)};
    elif [[ "$3" == *Health.Status* ]]; then echo healthy;
    else echo true; fi
}}
wait_ready candidate 12.2
'''
                result=self.shell(code)
                self.assertEqual(result.returncode == 0,expected,result.stderr)
                self.assertNotIn('private-server-name',result.stdout+result.stderr)

    def test_database_permissions_are_private_and_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); (root/'data').mkdir()
            files=[root/'data'/name for name in ['jellyfin.db','jellyfin.db-wal','jellyfin.db-shm']]
            for path in files: path.touch(); path.chmod(0o755)
            code=function('protect_database')+'\nchown() { test "$1" = 1001:1001; }; protect_database "$1"\n'
            result=subprocess.run(['bash','-euo','pipefail','-c',code,'test',str(root)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            for path in files: self.assertEqual(path.stat().st_mode&0o777,0o600)
            target=root/'other'; target.touch(); target.chmod(0o644)
            files[1].unlink(); files[1].symlink_to(target)
            result=subprocess.run(['bash','-euo','pipefail','-c',code,'test',str(root)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(target.stat().st_mode&0o777,0o644)

    def test_major_pin_accepts_12_and_rejects_unbounded_or_other_majors(self):
        code = re.search(r'^validate_jellyfin_pin\(\) \{\n.*?^\}', (ROOT/'scripts/ops/media-app-update.sh').read_text(),re.M|re.S)[0]
        for image, expected in [('jellyfin/jellyfin:12',True),('jellyfin/jellyfin:10',False),('jellyfin/jellyfin:13',False),('jellyfin/jellyfin:latest',False)]:
            with self.subTest(image=image):
                result = self.shell(code + f'''
log() {{ :; }}
compose_config() {{ printf '%s\\n' '  image: {image}'; }}
JELLYFIN_ALLOWED_MAJOR=12; JELLYFIN_COMPOSE_DIR=/unused
validate_jellyfin_pin
''')
                self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_new_numbering_parses_hotfix_and_warns_on_next_major(self):
        text=(ROOT/'scripts/ops/media-app-update.sh').read_text()
        code='\n'.join(re.search(r'^'+name+r'\(\) \{\n.*?^\}',text,re.M|re.S)[0] for name in ['major_from_tag','check_latest_major'])
        code += '''
log() { :; }; LATEST_VERSION_SUMMARY=(); MAJOR_UPDATE_MESSAGES=()
github_latest_tag() { printf '%s' "$TAG"; }
TAG=v12.2; check_latest_major Jellyfin unused 12
test "${#MAJOR_UPDATE_MESSAGES[@]}" = 0
TAG=v13.0; check_latest_major Jellyfin unused 12
test "${#MAJOR_UPDATE_MESSAGES[@]}" = 1
'''
        result = self.shell(code)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
