"""End-to-end tests for ship_logs.py against a real S3 API (SeaweedFS), using the same
apt boto3 as the servers. Run through test.sh, which starts the containers."""
import gzip
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

import boto3
import botocore.config

SCRIPT = '/work/ship_logs.py'
ENDPOINT = os.environ['TEST_ENDPOINT']
BUCKET = 'testlogs'
PREFIX = 'unglue.it/test'
TODAY = datetime.now(timezone.utc).strftime('%Y%m%d')
OLD_DAY = (datetime.now(timezone.utc) - timedelta(days=5)).strftime('%Y%m%d')
OLDER_DAY = (datetime.now(timezone.utc) - timedelta(days=6)).strftime('%Y%m%d')


def s3():
    return boto3.client('s3', endpoint_url=ENDPOINT, region_name='us-east-1',
                        config=botocore.config.Config(s3={'addressing_style': 'path'}))


class Base(unittest.TestCase):
    def setUp(self):
        self.client = s3()
        try:
            self.client.create_bucket(Bucket=BUCKET)
        except self.client.exceptions.BucketAlreadyOwnedByYou:
            pass
        self.wipe_bucket()
        self.tmp = tempfile.mkdtemp()
        self.root = os.path.join(self.tmp, 'root')
        self.home = os.path.join(self.tmp, 'home')
        self.state = os.path.join(self.tmp, 'state')
        self.mail = os.path.join(self.tmp, 'mail')
        self.sendmail = os.path.join(self.tmp, 'sendmail')
        with open(self.sendmail, 'w') as f:
            f.write(f'#!/bin/sh\ncat >> {self.mail}\necho ===END=== >> {self.mail}\n')
        os.chmod(self.sendmail, os.stat(self.sendmail).st_mode | stat.S_IEXEC)
        for d in ('var/log/apache2', 'var/log/regluit/status_sampler', 'var/log/celery'):
            os.makedirs(os.path.join(self.root, d))
        os.makedirs(self.home)
        self.write('var/log/apache2', f'{OLD_DAY}_access.log', b'apache old day\n')
        self.write('var/log/apache2', f'{OLD_DAY}_error.log', b'apache old errors\n')
        self.write('var/log/apache2', f'{TODAY}_access.log', b'apache today, unfinished\n')
        self.write('var/log/apache2', 'error.log', b'apache undated\n')
        self.write('var/log/regluit', 'downloads.log', b'downloads now\n')
        self.write('var/log/regluit', 'downloads.log.1', b'downloads rotated A\n')
        self.write('var/log/regluit', 'downloads.log.2', b'downloads rotated B\n')
        self.write('var/log/regluit', 'unglue.it.log', b'app now\n')
        self.write('var/log/regluit', 'unglue.it.log.1', b'app rotated\n')
        self.write('var/log/regluit', 'doab-harvest.log', b'doab\n')
        self.write('var/log/regluit/status_sampler', f'{OLD_DAY}.log', b'sampler old\n')
        self.write('var/log/regluit/status_sampler', f'{TODAY}.log', b'sampler today\n')
        self.write('var/log/celery', 'metrics-2026-10-01.html', b'<html>metrics</html>')
        self.write('var/log/celery', 'w1.log', b'celery\n')
        self.write('var/log/celery', 'beat.log', b'not shipped\n')

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def wipe_bucket(self):
        for obj in self.client.list_objects_v2(Bucket=BUCKET).get('Contents', []):
            self.client.delete_object(Bucket=BUCKET, Key=obj['Key'])

    def write(self, folder, name, data):
        with open(os.path.join(self.root, folder, name), 'wb') as f:
            f.write(data)

    def path(self, folder, name):
        return os.path.join(self.root, folder, name)

    def run_ship(self, endpoint=ENDPOINT, extra_env=None, *more):
        env = dict(os.environ)
        env.update(extra_env or {})
        cmd = [sys.executable, SCRIPT, '--bucket', BUCKET, '--prefix', PREFIX,
               '--mail-to', 'to@example.org', '--mail-from', 'from@example.org',
               '--state-dir', self.state, '--sendmail', self.sendmail,
               '--root', self.root, '--home', self.home, *(more or ('--min-free-mb', '50'))]
        if endpoint:
            cmd += ['--test-endpoint', endpoint]
        return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=240)

    def keys(self):
        contents = self.client.list_objects_v2(Bucket=BUCKET).get('Contents', [])
        return sorted(obj['Key'][len(PREFIX) + 1:] for obj in contents)

    def etags(self):
        contents = self.client.list_objects_v2(Bucket=BUCKET).get('Contents', [])
        return {obj['Key']: (obj['ETag'], obj['LastModified']) for obj in contents}

    def fetch(self, relative):
        return self.client.get_object(Bucket=BUCKET, Key=f'{PREFIX}/{relative}')

    def mails(self):
        if not os.path.exists(self.mail):
            return 0
        with open(self.mail) as f:
            return f.read().count('===END===')

    def tree_fingerprint(self):
        """Every file under the fake server: name, bytes, mode, mtime."""
        out = {}
        for base, _, names in os.walk(self.root):
            for name in names:
                p = os.path.join(base, name)
                st = os.stat(p)
                with open(p, 'rb') as f:
                    out[p] = (hashlib.sha256(f.read()).hexdigest(), st.st_mode, st.st_mtime_ns)
        return out


def sha(data):
    return hashlib.sha256(data).hexdigest()


class FirstRun(Base):
    def test_ships_the_right_files_with_verifiable_names(self):
        r = self.run_ship()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        day = datetime.now(timezone.utc).strftime('%Y-%m-%d')
        expected = sorted([
            f'apache/{OLD_DAY}_access.log.{sha(b"apache old day" + bytes([10]))}.gz',
            f'apache/{OLD_DAY}_error.log.{sha(b"apache old errors" + bytes([10]))}.gz',
            f'rotated/downloads.log.{sha(b"downloads rotated A" + bytes([10]))}.gz',
            f'rotated/downloads.log.{sha(b"downloads rotated B" + bytes([10]))}.gz',
            f'rotated/unglue.it.log.{sha(b"app rotated" + bytes([10]))}.gz',
            f'metrics/metrics-2026-10-01.html.{sha(b"<html>metrics</html>")}.gz',
            f'sampler/{OLD_DAY}.log.{sha(b"sampler old" + bytes([10]))}.gz',
            f'live/{day}/downloads.log.gz', f'live/{day}/unglue.it.log.gz',
            f'live/{day}/doab-harvest.log.gz', f'live/{day}/w1.log.gz', f'live/{day}/error.log.gz',
        ])
        self.assertEqual(self.keys(), expected)

    def test_object_decompresses_to_the_original_and_records_its_hash(self):
        self.run_ship()
        relative = f'rotated/downloads.log.{sha(b"downloads rotated A" + bytes([10]))}.gz'
        obj = self.fetch(relative)
        self.assertEqual(gzip.decompress(obj['Body'].read()), b'downloads rotated A\n')
        self.assertEqual(obj['Metadata']['uncompressed-sha256'], sha(b'downloads rotated A\n'))
        self.assertTrue(obj['Metadata']['source-path'].endswith('downloads.log.1'))

    def test_server_files_are_untouched(self):
        before = self.tree_fingerprint()
        self.run_ship()
        self.assertEqual(self.tree_fingerprint(), before)

    def test_large_file_goes_multipart_and_survives(self):
        data = os.urandom(20 * 1024 * 1024)      # incompressible, so over the 16 MB threshold
        self.write('var/log/apache2', f'{OLDER_DAY}_access.log', data)
        r = self.run_ship()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        obj = self.fetch(f'apache/{OLDER_DAY}_access.log.{sha(data)}.gz')
        self.assertEqual(gzip.decompress(obj['Body'].read()), data)

    def test_temp_copies_are_removed(self):
        self.run_ship()
        self.assertFalse(os.path.exists(os.path.join(self.state, 'tmp')))


class LaterRuns(Base):
    def test_second_run_sends_nothing(self):
        self.run_ship()
        before = self.etags()
        self.assertTrue(before, 'the first run should have shipped something')
        r = self.run_ship()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('sent=0', r.stdout)
        self.assertEqual(self.etags(), before)

    def test_renumbered_file_does_not_upload_again(self):
        self.run_ship()
        before = self.etags()
        self.assertTrue(before, 'the first run should have shipped something')
        os.rename(self.path('var/log/regluit', 'downloads.log.2'), self.path('var/log/regluit', 'downloads.log.3'))
        os.rename(self.path('var/log/regluit', 'downloads.log.1'), self.path('var/log/regluit', 'downloads.log.2'))
        r = self.run_ship()
        self.assertIn('sent=0', r.stdout, r.stdout)
        self.assertEqual(self.etags(), before)

    def test_gzipped_apache_log_maps_to_the_same_object(self):
        self.run_ship()
        before = self.etags()
        self.assertTrue(before, 'the first run should have shipped something')
        subprocess.run(['gzip', '-q', self.path('var/log/apache2', f'{OLD_DAY}_access.log')], check=True)
        r = self.run_ship()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('sent=0', r.stdout, r.stdout)
        self.assertEqual(self.etags(), before)

    def test_already_gzipped_file_uploads_as_is_under_its_uncompressed_hash(self):
        original = b'old gz day\n'
        with gzip.open(self.path('var/log/apache2', f'{OLDER_DAY}_access.log.gz'), 'wb') as f:
            f.write(original)
        self.run_ship()
        obj = self.fetch(f'apache/{OLDER_DAY}_access.log.{sha(original)}.gz')
        self.assertEqual(gzip.decompress(obj['Body'].read()), original)

    def test_rotated_file_still_being_written_ships_as_new_and_keeps_the_old(self):
        self.run_ship()
        first = f'rotated/unglue.it.log.{sha(b"app rotated" + bytes([10]))}.gz'
        self.assertIn(first, self.keys())
        self.write('var/log/regluit', 'unglue.it.log.1', b'app rotated\nmore lines\n')
        self.run_ship()
        keys = self.keys()
        self.assertIn(first, keys)
        self.assertIn(f'rotated/unglue.it.log.{sha(b"app rotated" + bytes([10]) + b"more lines" + bytes([10]))}.gz', keys)

    def test_live_file_uploads_only_when_changed(self):
        self.run_ship()
        day = datetime.now(timezone.utc).strftime('%Y-%m-%d')
        relative = f'live/{day}/downloads.log.gz'
        self.write('var/log/regluit', 'downloads.log', b'downloads now\nand more\n')
        r = self.run_ship()
        self.assertIn('sent=1', r.stdout, r.stdout)
        self.assertEqual(gzip.decompress(self.fetch(relative)['Body'].read()), b'downloads now\nand more\n')

    def test_lost_state_resends_safely_under_the_same_names(self):
        self.run_ship()
        keys = self.keys()
        shutil.rmtree(self.state)
        r = self.run_ship()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.keys(), keys)

    def test_corrupt_state_starts_over_without_failing(self):
        self.run_ship()
        with open(os.path.join(self.state, 'state.json'), 'w') as f:
            f.write('{ not json')
        r = self.run_ship()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.mails(), 0)

    def test_empty_file_is_skipped_quietly(self):
        self.write('var/log/celery', 'w1.log', b'')
        r = self.run_ship()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse([k for k in self.keys() if k.endswith('/w1.log.gz')])


class Failures(Base):
    DEAD = 'http://127.0.0.1:9'    # nothing listens here

    def test_one_mail_per_episode_then_recovery_rearms_it(self):
        r = self.run_ship(endpoint=self.DEAD)
        self.assertEqual(r.returncode, 1)
        self.assertIn('FAILED', r.stdout)
        self.assertEqual(self.mails(), 1)
        self.run_ship(endpoint=self.DEAD)
        self.assertEqual(self.mails(), 1, 'a second failing night must not mail again')
        r = self.run_ship()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.mails(), 1, 'recovery sends no mail')
        self.assertFalse(os.path.exists(os.path.join(self.state, 'alert_sent')))
        self.write('var/log/regluit', 'downloads.log', b'new lines to send\n')    # or there's nothing to fail on
        self.run_ship(endpoint=self.DEAD)
        self.assertEqual(self.mails(), 2, 'a new failure mails again')

    def test_gives_up_after_three_failures_in_a_row(self):
        r = self.run_ship(endpoint=self.DEAD)
        self.assertIn('stopped after 3 failures in a row', r.stdout, r.stdout)

    def test_rejected_upload_is_a_failure(self):
        r = self.run_ship(extra_env={'AWS_SECRET_ACCESS_KEY': 'wrong-secret'})
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertEqual(self.mails(), 1)
        self.assertEqual(self.keys(), [])

    def test_failed_mail_is_retried_next_run(self):
        with open(self.sendmail, 'w') as f:
            f.write('#!/bin/sh\nexit 1\n')
        self.run_ship(endpoint=self.DEAD)
        self.assertFalse(os.path.exists(os.path.join(self.state, 'alert_sent')))

    def test_corrupt_gz_is_reported_and_the_rest_still_ship(self):
        with open(self.path('var/log/apache2', f'{OLDER_DAY}_access.log.gz'), 'wb') as f:
            f.write(b'this is not gzip')
        r = self.run_ship()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertEqual(self.mails(), 1)
        self.assertTrue(self.keys(), 'the good files should still have shipped')

    def test_unreadable_folder_is_a_problem_not_a_quiet_gap(self):
        shutil.rmtree(self.path('var/log/celery', ''))
        r = self.run_ship()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn('cannot list', r.stdout)
        self.assertEqual(self.mails(), 1)

    def test_low_disk_stops_before_compressing_and_reports_it(self):
        r = self.run_ship(ENDPOINT, None, '--min-free-mb', str(1024 ** 3))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn('stopped early', r.stdout)
        self.assertEqual(self.keys(), [])
        self.assertEqual(self.mails(), 1)

    def test_no_files_at_all_is_a_problem(self):
        for base in ('var/log/apache2', 'var/log/regluit', 'var/log/celery'):
            for name in os.listdir(os.path.join(self.root, base)):
                p = os.path.join(self.root, base, name)
                if os.path.isfile(p):
                    os.unlink(p)
        for name in os.listdir(self.path('var/log/regluit/status_sampler', '')):
            os.unlink(self.path('var/log/regluit/status_sampler', name))
        r = self.run_ship()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn('found no log files', r.stdout)

    def test_second_copy_leaves_a_running_one_alone(self):
        import fcntl
        os.makedirs(self.state)
        lock = open(os.path.join(self.state, 'lock'), 'w')
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            r = self.run_ship()
        finally:
            lock.close()
        self.assertEqual(r.returncode, 0)
        self.assertIn('another run is still going', r.stdout)
        self.assertEqual(self.keys(), [])


class RoleOnly(Base):
    """Without --test-endpoint: must refuse every credential but the role, even
    when a usable key is sitting in each place AWS's libraries look. The container
    has no metadata service, so the right answer here is failure."""

    def test_ignores_keys_in_the_environment_and_files(self):
        aws_dir = os.path.join(self.home, '.aws')
        os.makedirs(aws_dir)
        creds = os.path.join(aws_dir, 'credentials')
        with open(creds, 'w') as f:
            f.write('[default]\naws_access_key_id = AKIAFILEKEY\naws_secret_access_key = filesecret\n')
        boto_cfg = os.path.join(self.home, '.boto')
        with open(boto_cfg, 'w') as f:
            f.write('[Credentials]\naws_access_key_id = AKIABOTOKEY\naws_secret_access_key = botosecret\n')
        r = self.run_ship(endpoint=None, extra_env={
            'HOME': self.home,
            'AWS_ACCESS_KEY_ID': 'AKIAENVKEY', 'AWS_SECRET_ACCESS_KEY': 'envsecret',
            'AWS_SHARED_CREDENTIALS_FILE': creds, 'BOTO_CONFIG': boto_cfg,
            'AWS_METADATA_SERVICE_NUM_ATTEMPTS': '1', 'AWS_METADATA_SERVICE_TIMEOUT': '1',
        })
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn('no instance role found', r.stdout)
        self.assertEqual(self.mails(), 1)


class DryRun(Base):
    def test_dry_run_changes_nothing_anywhere(self):
        before = self.tree_fingerprint()
        r = self.run_ship(None, None, '--dry-run')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('0 problems', r.stdout)
        self.assertEqual(self.tree_fingerprint(), before)
        self.assertEqual(self.keys(), [])
        self.assertFalse(os.path.exists(self.state))


class ChecksTakeNoSettings(unittest.TestCase):
    """The README's by-hand checks are typed without the cron line's settings."""

    def run_bare(self, *flags):
        env = dict(os.environ, AWS_METADATA_SERVICE_NUM_ATTEMPTS='1', AWS_METADATA_SERVICE_TIMEOUT='1')
        return subprocess.run([sys.executable, SCRIPT, *flags], env=env, capture_output=True,
                              text=True, timeout=60)

    def test_whoami_reports_no_role_plainly(self):
        r = self.run_bare('--whoami')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn('no instance role found', r.stdout)

    def test_dry_run_needs_no_settings(self):
        with tempfile.TemporaryDirectory() as root:
            r = self.run_bare('--dry-run', '--root', root)
        self.assertIn('problems', r.stdout, r.stderr)

    def test_copying_without_settings_is_refused(self):
        r = self.run_bare()
        self.assertEqual(r.returncode, 2)
        self.assertIn('required to copy', r.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
