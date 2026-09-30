#!/usr/bin/env python3
"""Read-only: which kinds of request cost the server time?

Reads Apache access logs in the "combined_time" format that
roles/regluit_prod/templates/apache.conf.j2 configures (Apache "combined"
with %D, the response time in microseconds, appended last):
    %h %l %u %t "%r" %>s %O "%{Referer}i" "%{User-Agent}i" %D
cronolog writes one file per day: /var/log/apache2/YYYYMMDD_access.log.

Sorts every request into one URL family (first match wins):
    feedback    /feedback/...
    signin      /accounts/superlogin/...
    socialauth  /socialauth/login/...
    keyword     /free/kw.<keyword>/...
    free_deep   other /free/... with ?work_list= 51 or more
    opds        /api/opds... (covers /api/opdsjson/)
    other       everything else, including lines whose request is "-"
and prints, per family and in total: requests, distinct URLs (path + query),
server seconds (sum of %D), average seconds, requests and server seconds per
hour, and counts by HTTP status. Prints counts only: no IPs, user agents or
URLs.

Arguments are log paths (.gz ok, '-' for stdin) or YYYYMMDD dates
(-> /var/log/apache2/YYYYMMDD_access.log, or .gz if rotated). --since and
--until (ISO-8601; UTC unless an offset is given) keep only requests in
[since, until). Per-hour rates divide by the window's length: since..until
when given, otherwise the first..last request seen.

--compare [LOG ...] adds a second column set: the same families for other
logs (or, with no LOG, the same logs again) windowed by --compare-since and
--compare-until. Use it for before/after, e.g. a full day before a deploy
against the hours since.

Usage:
  ssh ubuntu@test.unglue.it 'python3 - /var/log/apache2/20260929_access.log' < scripts/url_family_report.py
  ssh ubuntu@test.unglue.it 'python3 - 20260929 --compare 20260930 --compare-since 2026-09-30T18:03:23Z' < scripts/url_family_report.py
"""
import argparse
import gzip
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, urlsplit

LINE_RE = re.compile(
    r'^\S+ \S+ \S+ \[(?P<time>[^\]]+)\] '
    r'"(?P<request>(?:[^"\\]|\\.)*)" '
    r'(?P<status>\d{3}) \S+ "(?:[^"\\]|\\.)*" "(?:[^"\\]|\\.)*" (?P<usec>\d+)\s*$')
TIME_RE = re.compile(r'^(\d{2})/(\w{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})$')
MONTHS = {m: i for i, m in enumerate(
    'Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'.split(), 1)}
FAMILIES = ('feedback', 'signin', 'socialauth', 'keyword', 'free_deep', 'opds', 'other')
FREE_DEEP_PAGE = 51


def log_paths(args):
    for a in args:
        if re.fullmatch(r'\d{8}', a):
            a = '/var/log/apache2/%s_access.log' % a
            if not os.path.exists(a) and os.path.exists(a + '.gz'):
                a += '.gz'
        yield a


def open_log(path):
    if path == '-':
        return sys.stdin
    if path.endswith('.gz'):
        return gzip.open(path, 'rt', encoding='utf-8', errors='replace')
    return open(path, encoding='utf-8', errors='replace')


def parse_log_time(s):
    # Parsed by hand: strptime's %b depends on the locale.
    m = TIME_RE.match(s)
    if not m:
        return None
    day, mon, year, hh, mm, ss, sign, oh, om = m.groups()
    if mon not in MONTHS:
        return None
    offset = timedelta(hours=int(oh), minutes=int(om)) * (-1 if sign == '-' else 1)
    return datetime(int(year), MONTHS[mon], int(day), int(hh), int(mm), int(ss),
                    tzinfo=timezone(offset))


def parse_iso(s):
    """ISO-8601 on the command line; naive means UTC. 'Z' works on Python 3.8."""
    try:
        t = datetime.fromisoformat(s[:-1] + '+00:00' if s.endswith('Z') else s)
    except ValueError:
        raise argparse.ArgumentTypeError('not an ISO-8601 time: %r' % s)
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def page_of(query):
    # Same rule as el_pagination: missing or non-integer means page 1.
    try:
        return int(parse_qs(query).get('work_list', ['1'])[0])
    except ValueError:
        return 1


def family(url):
    if url.startswith('/feedback/'):
        return 'feedback'
    if url.startswith('/accounts/superlogin/'):
        return 'signin'
    if url.startswith('/socialauth/login/'):
        return 'socialauth'
    if url.startswith('/free/kw.'):
        return 'keyword'
    if url.startswith('/free/'):
        if page_of(urlsplit(url).query) >= FREE_DEEP_PAGE:
            return 'free_deep'
        return 'other'
    if url.startswith('/api/opds'):
        return 'opds'
    return 'other'


def new_cell():
    return {'n': 0, 'secs': 0.0, 'urls': set(), 'status': {}}


def add(cell, url, status, secs):
    cell['n'] += 1
    cell['secs'] += secs
    cell['urls'].add(url)
    cell['status'][status] = cell['status'].get(status, 0) + 1


def tally(paths, since=None, until=None):
    fams = {f: new_cell() for f in FAMILIES}
    total = new_cell()
    info = {'paths': paths, 'lines': 0, 'malformed': 0, 'outside': 0,
            'first': None, 'last': None, 'since': since, 'until': until}
    for path in paths:
        with open_log(path) as fh:
            for line in fh:
                info['lines'] += 1
                m = LINE_RE.match(line)
                t = m and parse_log_time(m.group('time'))
                if not t:
                    info['malformed'] += 1
                    continue
                if (since and t < since) or (until and t >= until):
                    info['outside'] += 1
                    continue
                info['first'] = t if info['first'] is None else min(info['first'], t)
                info['last'] = t if info['last'] is None else max(info['last'], t)
                # "%r" is METHOD TARGET PROTOCOL, or "-" for a connection that
                # sent no request; those have no URL and land in "other".
                parts = m.group('request').split(' ')
                url = parts[1] if len(parts) >= 2 else '-'
                status, secs = m.group('status'), int(m.group('usec')) / 1e6
                add(fams[family(url)], url, status, secs)
                add(total, url, status, secs)
    start = since or info['first']
    end = until or info['last']
    info['hours'] = (end - start).total_seconds() / 3600 if start and end else 0.0
    return fams, total, info


def fmt_time(t):
    return t.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ') if t else '-'


def describe(label, info, out):
    out.write('%s: %s\n' % (label, ', '.join(info['paths'])))
    out.write('  window %s .. %s (%.2f h; %s)\n' % (
        fmt_time(info['since'] or info['first']), fmt_time(info['until'] or info['last']),
        info['hours'],
        'from --since/--until' if info['since'] and info['until'] else
        'ends not given on the command line are the first/last request seen'))
    out.write('  lines read %d, in window %d, outside window %d, malformed %d\n' % (
        info['lines'], info['lines'] - info['outside'] - info['malformed'],
        info['outside'], info['malformed']))


def statuses(cell):
    return ', '.join('%s: %d' % kv for kv in sorted(cell['status'].items())) or '-'


def per_hour(x, hours):
    return x / hours if hours else float('nan')


def report(fams, total, info, out=sys.stdout):
    describe('logs', info, out)
    out.write('\n%-10s %8s %8s %9s %6s %8s %7s  %s\n' % (
        'family', 'requests', 'distinct', 'server_s', 'avg_s', 'req/h', 's/h', 'statuses'))
    for name, c in [(f, fams[f]) for f in FAMILIES] + [('TOTAL', total)]:
        out.write('%-10s %8d %8d %9.0f %6.2f %8.1f %7.1f  %s\n' % (
            name, c['n'], len(c['urls']), c['secs'], c['secs'] / c['n'] if c['n'] else 0,
            per_hour(c['n'], info['hours']), per_hour(c['secs'], info['hours']), statuses(c)))


def compare(a, b, out=sys.stdout):
    (fa, ta, ia), (fb, tb, ib) = a, b
    describe('A', ia, out)
    describe('B', ib, out)
    out.write('\nrates are per hour of each window; distinct URLs are not normalized\n')
    out.write('%-10s | %8s %7s %8s %6s | %8s %7s %8s %6s | %7s\n' % (
        'family', 'A req/h', 'A s/h', 'A dist', 'A avg', 'B req/h', 'B s/h', 'B dist', 'B avg',
        'req/h x'))
    rows = [(f, fa[f], fb[f]) for f in FAMILIES] + [('TOTAL', ta, tb)]
    for name, ca, cb in rows:
        ra, rb = per_hour(ca['n'], ia['hours']), per_hour(cb['n'], ib['hours'])
        out.write('%-10s | %8.1f %7.1f %8d %6.2f | %8.1f %7.1f %8d %6.2f | %7s\n' % (
            name,
            ra, per_hour(ca['secs'], ia['hours']), len(ca['urls']),
            ca['secs'] / ca['n'] if ca['n'] else 0,
            rb, per_hour(cb['secs'], ib['hours']), len(cb['urls']),
            cb['secs'] / cb['n'] if cb['n'] else 0,
            '%.2f' % (rb / ra) if ra else '-'))
    out.write('\nstatuses (raw counts)\n')
    for name, ca, cb in rows:
        out.write('%-10s A: %s\n%-10s B: %s\n' % (name, statuses(ca), '', statuses(cb)))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('logs', nargs='+', help="log paths (.gz ok, '-' for stdin) or YYYYMMDD")
    ap.add_argument('--since', type=parse_iso, help='keep requests at or after this time')
    ap.add_argument('--until', type=parse_iso, help='keep requests before this time')
    ap.add_argument('--compare', nargs='*', metavar='LOG',
                    help='second set of logs for a side-by-side table (none: same logs)')
    ap.add_argument('--compare-since', type=parse_iso)
    ap.add_argument('--compare-until', type=parse_iso)
    args = ap.parse_args(argv)
    paths_a = list(log_paths(args.logs))
    if args.compare is None:
        if args.compare_since or args.compare_until:
            ap.error('--compare-since/--compare-until need --compare')
        report(*tally(paths_a, args.since, args.until))
        return
    paths_b = list(log_paths(args.compare)) or paths_a
    if '-' in paths_a and '-' in paths_b:
        ap.error("stdin ('-') can be read only once")
    compare(tally(paths_a, args.since, args.until),
            tally(paths_b, args.compare_since, args.compare_until))


if __name__ == '__main__':
    main()
