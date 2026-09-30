#!/usr/bin/env python3
"""Replay an Apache access log through a simulated shared cache.

For each URL family (/api/opds*, /free/, other) and each cache lifetime
(10 min, 1 h, 24 h), reports how many successful GETs a cache keyed on the
full URL (path + query string) would have answered, and how many seconds of
server time (%D) those answers would have saved.

Log format (regluit-provisioning roles/regluit_prod/templates/apache.conf.j2,
LogFormat "combined_time"): Apache "combined" with %D (microseconds) appended
LAST:
    %h %l %u %t "%r" %>s %O "%{Referer}i" "%{User-Agent}i" %D

Model and its limits (read before quoting a number):
- Only GET with status 200 is replayed; everything else is skipped, which is
  also what the app caches.
- Requests are replayed in %t order (Apache writes a line when the response
  finishes, so file order is not quite arrival order).
- First request for a URL is a miss and fills the cache at its arrival time;
  a later request within the lifetime is a hit and saves its own %D.
  (The real fill happens when the response finishes, so this slightly
  overstates hits for URLs requested again within one response time.)
- The log cannot tell logged-in users apart, and the app only caches
  anonymous requests, so hit rates are an upper bound.
- After the OPDS cache is deployed, hits are fast, so %D totals for
  /api/opds* will drop; replaying a post-deploy log estimates what an ideal
  cache would still save beyond what the real one already does.

Stdlib only, read-only; holds the parsed 200 GETs in memory to sort them. Prints counts only (no IPs, user agents or URLs).
Args: log paths (.gz ok, '-' for stdin) or YYYYMMDD dates
(-> /var/log/apache2/YYYYMMDD_access.log, or .gz if rotated).

Usage:
    ssh ubuntu@test.unglue.it 'python3 - 20260929' < scripts/cache_hit_estimate.py
    ssh ubuntu@test.unglue.it 'python3 - --ttl 600 --ttl 3600 20260928 20260929' < scripts/cache_hit_estimate.py
"""
import argparse
import gzip
import os
import re
import sys
from collections import defaultdict
from datetime import datetime

LINE_RE = re.compile(
    r'^(?P<host>\S+) \S+ \S+ \[(?P<time>[^\]]+)\] '
    r'"(?P<method>[A-Z]+) (?P<url>\S+)(?: [^"]*)?" '
    r'(?P<status>\d{3}) \S+ "(?:[^"\\]|\\.)*" "(?:[^"\\]|\\.)*" (?P<usec>\d+)\s*$'
)
TIME_FMT = '%d/%b/%Y:%H:%M:%S %z'
DEFAULT_TTLS = (600, 3600, 86400)
FAMILIES = ('/api/opds*', '/free/', 'other')


def family(url):
    if url.startswith('/api/opds'):  # covers /api/opds/ and /api/opdsjson/
        return '/api/opds*'
    if url.startswith('/free/'):
        return '/free/'
    return 'other'


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


def parse(paths, stats):
    """Yield (epoch_seconds, url, seconds) for 200 GETs; count skipped lines in stats."""
    for path in paths:
        with open_log(path) as f:
            for line in f:
                stats['lines'] += 1
                m = LINE_RE.match(line)
                if not m:
                    stats['unparsed'] += 1
                    continue
                if m['method'] != 'GET' or m['status'] != '200':
                    stats['not_200_get'] += 1
                    continue
                t = datetime.strptime(m['time'], TIME_FMT).timestamp()
                yield t, m['url'], int(m['usec']) / 1e6


def simulate(records, ttls):
    totals = defaultdict(lambda: {'req': 0, 'secs': 0.0, 'urls': set()})
    hits = {ttl: defaultdict(lambda: {'hits': 0, 'saved': 0.0}) for ttl in ttls}
    expiry = {ttl: {} for ttl in ttls}
    for t, url, secs in sorted(records):
        fam = family(url)
        tot = totals[fam]
        tot['req'] += 1
        tot['secs'] += secs
        tot['urls'].add(url)
        for ttl in ttls:
            exp = expiry[ttl]
            if exp.get(url, float('-inf')) > t:
                hits[ttl][fam]['hits'] += 1
                hits[ttl][fam]['saved'] += secs
            else:
                exp[url] = t + ttl
    return totals, hits


def label(ttl):
    if ttl % 3600 == 0:
        return '%dh' % (ttl // 3600)
    if ttl % 60 == 0:
        return '%dmin' % (ttl // 60)
    return '%ds' % ttl


def report(totals, hits, ttls, stats, out=sys.stdout):
    out.write('lines read: %d, unparsed: %d, skipped (not a 200 GET): %d\n\n' % (
        stats['lines'], stats['unparsed'], stats['not_200_get']))
    out.write('%-11s %8s %8s %11s' % ('family', 'requests', 'urls', 'server-s'))
    for ttl in ttls:
        out.write('  %20s' % ('hit%%  saved-s @%s' % label(ttl)))
    out.write('\n')
    for fam in FAMILIES:
        tot = totals.get(fam)
        if not tot:
            continue
        out.write('%-11s %8d %8d %11.0f' % (fam, tot['req'], len(tot['urls']), tot['secs']))
        for ttl in ttls:
            h = hits[ttl][fam]
            pct = 100.0 * h['hits'] / tot['req'] if tot['req'] else 0.0
            out.write('  %7.1f%%  %11.0f' % (pct, h['saved']))
        out.write('\n')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('logs', nargs='+', help="log paths (.gz ok, '-' for stdin) or YYYYMMDD")
    ap.add_argument('--ttl', type=int, action='append',
                    help='cache lifetime in seconds; repeatable (default 600, 3600, 86400)')
    args = ap.parse_args(argv)
    ttls = tuple(args.ttl) if args.ttl else DEFAULT_TTLS
    stats = {'lines': 0, 'unparsed': 0, 'not_200_get': 0}
    totals, hits = simulate(parse(log_paths(args.logs), stats), ttls)
    report(totals, hits, ttls, stats)


if __name__ == '__main__':
    main()
