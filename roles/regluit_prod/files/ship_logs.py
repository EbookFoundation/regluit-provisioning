#!/usr/bin/python3
"""Copy this server's logs to S3, nightly, so losing the server doesn't lose them.

It only copies. It deletes, renames and rewrites nothing under the log folders;
the only things it writes on the server are its own state folder and its log.

What goes where, under s3://<bucket>/<prefix>/:

  apache/    dated Apache logs from before today (UTC)
  rotated/   downloads.log.N and unglue.it.log.N
  metrics/   the daily metrics pages
  sampler/   status sampler days from before today (UTC)
  live/YYYY-MM-DD/  tonight's copy of the files that are still growing

Everything is named by a SHA-256 of the file's uncompressed contents, so an
upload can only ever replace identical contents. Two reasons from the real servers:

  * Rotation renumbers files, so downloads.log.3 today is downloads.log.4 after
    the next rotation. Syncing by file name would overwrite a different, older
    file in S3. Here a renumbered file hashes the same and isn't sent again.
  * Apache's logs get gzipped in place after two days. The hash is of the
    uncompressed contents, so the .gz maps to the object already sent.

Rotated files can't be assumed finished: on 11/2 unglue.it.log.1, .3 and .5 were
all being written to minutes apart, because processes hold the old file open
across a rotation. A file whose contents changed simply ships as a new object,
which costs a little storage and loses nothing.

Credentials: the instance role only, deliberately. AWS's libraries would prefer
a stored key if one existed, and this job must never pick up the app's keys. The
role can upload under one folder and can't read, list or delete, so "already
sent?" has to come from the local state file. If that file is lost the next run
sends everything again under the same names, which is harmless.
"""
import argparse
import fcntl
import gzip
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

CHUNK = 1024 * 1024
MAX_PROBLEMS_IN_MAIL = 10
# Several uploads failing in a row means S3 or the role is the problem, not one
# file. Stop instead of compressing every remaining log for nothing.
MAX_CONSECUTIVE_FAILURES = 3
REGION = 'us-east-1'

APACHE_DAY = re.compile(r'^(\d{8})_(access|error)\.log(\.gz)?$')
ROTATED = re.compile(r'^(downloads\.log|unglue\.it\.log)\.\d+$')
METRICS = re.compile(r'^metrics-\d{4}-\d{2}-\d{2}\.html$')
SAMPLER_DAY = re.compile(r'^(\d{8})\.log$')


class Item:
    """One file to consider. folder and name, plus its hash, decide its S3 key."""

    def __init__(self, path, folder, name, live=False):
        self.path, self.folder, self.name, self.live = path, folder, name, live


def stamp():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def say(message):
    print(f'{stamp()} {message}', flush=True)


def collect(root, home, today):
    """Return (items, problems). A log folder we can't read is a problem to
    report, never a quiet skip: that's how a copy silently stops covering
    something. A single file that's absent is normal."""
    items, problems = [], []
    log = os.path.join(root, 'var/log')

    def listing(folder):
        try:
            return sorted(os.listdir(folder))
        except OSError as exc:
            problems.append(f'cannot list {folder}: {exc}')
            return []

    apache = os.path.join(log, 'apache2')
    for name in listing(apache):
        m = APACHE_DAY.match(name)
        if m and m.group(1) < today:
            stem = name[:-3] if name.endswith('.gz') else name
            items.append(Item(os.path.join(apache, name), 'apache', stem))

    regluit = os.path.join(log, 'regluit')
    for name in listing(regluit):
        m = ROTATED.match(name)
        if m:
            # The number is left out of the S3 name on purpose: it isn't stable.
            items.append(Item(os.path.join(regluit, name), 'rotated', m.group(1)))

    celery = os.path.join(log, 'celery')
    for name in listing(celery):
        if METRICS.match(name):
            items.append(Item(os.path.join(celery, name), 'metrics', name))

    sampler = os.path.join(regluit, 'status_sampler')
    for name in listing(sampler):
        m = SAMPLER_DAY.match(name)
        if m and m.group(1) < today:
            items.append(Item(os.path.join(sampler, name), 'sampler', name))

    for path in (os.path.join(regluit, 'downloads.log'),
                 os.path.join(regluit, 'unglue.it.log'),
                 os.path.join(regluit, 'doab-harvest.log'),
                 os.path.join(celery, 'w1.log'),
                 os.path.join(apache, 'error.log'),
                 os.path.join(home, 'update_downloads.log')):
        if os.path.exists(path):
            items.append(Item(path, 'live', os.path.basename(path), live=True))
    return items, problems


def hash_and_compress(path, tmp_dir):
    """Read the file once, returning (sha256 of uncompressed contents, path of a
    gzip copy to upload, whether that copy is ours to delete). One pass, so the
    hash always describes exactly the bytes uploaded, even if the file is growing.
    An existing .gz is uploaded as it is, once we've read it through to prove it
    isn't truncated."""
    sha = hashlib.sha256()
    if path.endswith('.gz'):
        with gzip.open(path, 'rb') as src:
            for chunk in iter(lambda: src.read(CHUNK), b''):
                sha.update(chunk)
        return sha.hexdigest(), path, False
    fd, tmp_path = tempfile.mkstemp(dir=tmp_dir, suffix='.gz')
    try:
        with open(path, 'rb') as src, os.fdopen(fd, 'wb') as raw, \
                gzip.GzipFile(fileobj=raw, mode='wb', compresslevel=6, mtime=0) as out:
            for chunk in iter(lambda: src.read(CHUNK), b''):
                sha.update(chunk)
                out.write(chunk)
    except BaseException:
        os.unlink(tmp_path)
        raise
    return sha.hexdigest(), tmp_path, True


def load_state(path, destination):
    empty = {'destination': destination, 'seen': {}, 'shipped': {}, 'live': {}}
    try:
        with open(path) as f:
            state = json.load(f)
        if state.get('destination') != destination:
            # "Already sent" only means something for one destination. Without
            # this, a changed folder would report ok while receiving nothing.
            say(f'destination is now {destination}; sending everything to it')
            return empty
        return {k: state.get(k, v) for k, v in empty.items()}
    except FileNotFoundError:
        return empty
    except ValueError as exc:
        say(f'state file unreadable, starting over (re-sending is harmless): {exc}')
        return empty


def save_state(path, state):
    tmp = f'{path}.tmp'
    with open(tmp, 'w') as f:
        json.dump(state, f, sort_keys=True)
    os.replace(tmp, path)


def s3_client(test_endpoint):
    import boto3
    import botocore.config
    import botocore.session

    session = botocore.session.get_session()
    if not test_endpoint:
        # Role only: drop every other credential source, including the legacy
        # ~/.boto and /etc/boto.cfg ones this old a deployment could have.
        resolver = session.get_component('credential_provider')
        for provider in list(resolver.providers):
            if provider.METHOD != 'iam-role':
                resolver.remove(provider.METHOD)
    boto = boto3.Session(botocore_session=session, region_name=REGION)
    config = botocore.config.Config(
        retries={'max_attempts': 5, 'mode': 'standard'},
        connect_timeout=10, read_timeout=120,
        s3={'addressing_style': 'path'} if test_endpoint else {})
    if test_endpoint:
        return boto, boto.client('s3', endpoint_url=test_endpoint, config=config)
    if boto.get_credentials() is None:
        raise RuntimeError('no instance role found (is one attached to this server?)')
    return boto, boto.client('s3', config=config)


def ship(args, today, state, state_path, tmp_dir):
    """Returns (shipped, unchanged, bytes sent, problems)."""
    from boto3.s3.transfer import TransferConfig

    items, problems = collect(args.root, args.home, today)
    if not items and not problems:
        problems.append('found no log files at all; check the paths')
    # A role that can't upload fails below; this catches "no role" first, with a
    # clear message, before any file is compressed.
    _, client = s3_client(args.test_endpoint)
    transfer = TransferConfig(multipart_threshold=16 * CHUNK, multipart_chunksize=16 * CHUNK,
                              max_concurrency=2)
    shipped = unchanged = sent_bytes = consecutive = 0
    seen_now = {}
    live_day = f'{today[:4]}-{today[4:6]}-{today[6:]}'

    for item in items:
        tmp_copy = None
        try:
            st = os.stat(item.path)
            if st.st_size == 0:
                continue
            fingerprint = f'{item.path}|{st.st_size}|{st.st_mtime_ns}'
            sha = state['seen'].get(fingerprint)
            if sha:
                seen_now[fingerprint] = sha
            already = sha and (state['live'].get(item.name) == sha if item.live
                               else f'{item.folder}/{item.name}.{sha}.gz' in state['shipped'])
            if already:
                unchanged += 1
                continue
            # The compressed copy can't be much bigger than the file, so leave
            # room for all of it. An existing .gz needs no temporary copy.
            needed = args.min_free_mb * CHUNK + (0 if item.path.endswith('.gz') else st.st_size)
            if shutil.disk_usage(tmp_dir).free < needed:
                problems.append(f'stopped early: under {args.min_free_mb} MB free on the disk')
                break
            sha, upload_path, ours = hash_and_compress(item.path, tmp_dir)
            if ours:
                tmp_copy = upload_path
            seen_now[fingerprint] = sha
            if item.live:
                if state['live'].get(item.name) == sha:
                    unchanged += 1
                    continue
                relative = f'live/{live_day}/{item.name}.{sha}.gz'
            else:
                relative = f'{item.folder}/{item.name}.{sha}.gz'
                if relative in state['shipped']:     # renumbered or gzipped since
                    unchanged += 1
                    continue
            size = os.path.getsize(upload_path)
            client.upload_file(upload_path, args.bucket, f'{args.prefix}/{relative}', Config=transfer, ExtraArgs={
                # S3 recomputes this on receipt and rejects a mismatch.
                'ChecksumAlgorithm': 'SHA256',
                'ContentType': 'application/gzip',
                'Metadata': {
                    'uncompressed-sha256': sha,
                    'source-path': item.path,
                    'source-mtime': datetime.fromtimestamp(st.st_mtime, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                }})
            if item.live:
                state['live'][item.name] = sha
            else:
                state['shipped'][relative] = stamp()
            state['seen'][fingerprint] = sha
            save_state(state_path, state)     # a crash loses at most one file's bookkeeping
            shipped += 1
            sent_bytes += size
            consecutive = 0
            say(f'sent {relative} ({size} bytes)')
        except FileNotFoundError:
            continue                         # rotated, gzipped or cleaned up under us; next run sees it
        except Exception as exc:
            consecutive += 1
            problems.append(f'{item.path}: {type(exc).__name__}: {exc}')
            if consecutive >= MAX_CONSECUTIVE_FAILURES:
                problems.append(f'stopped after {consecutive} failures in a row')
                break
        finally:
            if tmp_copy and os.path.exists(tmp_copy):
                os.unlink(tmp_copy)

    # Only forget files on a run that looked at everything; otherwise the files
    # after an early stop would all have to be hashed again.
    if not problems:
        state['seen'] = seen_now
    return shipped, unchanged, sent_bytes, problems


def send_alert(args, problems, flag):
    """One mail per failure episode: the flag is set only after a successful
    send, so a mail failure retries next run, and cleared by the next clean run."""
    if os.path.exists(flag):
        return
    host = socket.gethostname()
    listed = problems[:MAX_PROBLEMS_IN_MAIL]
    more = len(problems) - len(listed)
    message = '\n'.join([
        f'From: {args.mail_from}',
        f'To: {args.mail_to}',
        f'Subject: [unglue.it] nightly log copy FAILED on {host}',
        '',
        f'The nightly copy of logs to s3://{args.bucket}/{args.prefix}/ had problems at {stamp()}.',
        'Nothing on the server was changed. Logs still on the server will be picked up by',
        'the next good run, but the server keeps deleting old ones, so do not leave this for',
        'more than a few days.',
        '',
        *listed,
        *([f'...and {more} more.'] if more > 0 else []),
        '',
        f'Log: /var/log/regluit/ship_logs.log on {host}. No more mail until a run succeeds.',
    ]) + '\n'
    try:
        subprocess.run([args.sendmail, '-t'], input=message.encode(), check=True, timeout=60)
    except Exception as exc:
        say(f'could not send the alert, will retry next run: {exc}')
        return
    with open(flag, 'w') as f:
        f.write(stamp() + '\n')


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--bucket')
    p.add_argument('--prefix', help='folder in the bucket, e.g. unglue.it/prod')
    p.add_argument('--mail-to')
    p.add_argument('--mail-from')
    p.add_argument('--state-dir', default='/var/lib/log_ship')
    p.add_argument('--sendmail', default='/usr/sbin/sendmail')
    p.add_argument('--min-free-mb', type=int, default=2048,
                   help='stop rather than leave less than this free after compressing a file')
    p.add_argument('--root', default='/', help='for tests: where var/log is')
    p.add_argument('--home', default=os.path.expanduser('~'))
    p.add_argument('--test-endpoint', help='for tests: an S3 lookalike, using keys from the environment')
    p.add_argument('--dry-run', action='store_true', help='list what would be considered; touch nothing')
    p.add_argument('--whoami', action='store_true', help='print the AWS identity this job would use')
    args = p.parse_args()
    today = datetime.now(timezone.utc).strftime('%Y%m%d')

    if args.dry_run:
        items, problems = collect(args.root, args.home, today)
        for item in items:
            print(f'{item.folder:8} {item.path}')
        for problem in problems:
            print(f'PROBLEM  {problem}')
        print(f'{len(items)} files, {len(problems)} problems')
        return 1 if problems else 0

    if args.whoami:
        try:
            boto, _ = s3_client(args.test_endpoint)
            print(boto.client('sts').get_caller_identity()['Arn'])
        except Exception as exc:
            print(f'{type(exc).__name__}: {exc}')
            return 1
        return 0

    if not (args.bucket and args.prefix and args.mail_to and args.mail_from):
        p.error('--bucket, --prefix, --mail-to and --mail-from are required to copy')
    args.prefix = args.prefix.strip('/')

    os.makedirs(args.state_dir, exist_ok=True)
    lock = open(os.path.join(args.state_dir, 'lock'), 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        say('another run is still going; leaving it to finish')
        return 0

    state_path = os.path.join(args.state_dir, 'state.json')
    flag = os.path.join(args.state_dir, 'alert_sent')
    tmp_dir = os.path.join(args.state_dir, 'tmp')
    shutil.rmtree(tmp_dir, ignore_errors=True)   # anything left here is from a killed run
    os.makedirs(tmp_dir)
    started = time.monotonic()
    state = load_state(state_path, f'{args.bucket}/{args.prefix}')
    try:
        shipped, unchanged, sent_bytes, problems = ship(args, today, state, state_path, tmp_dir)
    except Exception as exc:
        # Includes boto3 failing to import, so a broken install still sends mail.
        shipped = unchanged = sent_bytes = 0
        problems = [f'{type(exc).__name__}: {exc}']
    save_state(state_path, state)
    shutil.rmtree(tmp_dir, ignore_errors=True)
    say(f'{"FAILED" if problems else "ok"} sent={shipped} unchanged={unchanged} '
        f'bytes={sent_bytes} problems={len(problems)} seconds={time.monotonic() - started:.0f}')
    for problem in problems:
        say(f'problem: {problem}')
    if problems:
        send_alert(args, problems, flag)
        return 1
    if os.path.exists(flag):
        os.unlink(flag)
    return 0


if __name__ == '__main__':
    sys.exit(main())
