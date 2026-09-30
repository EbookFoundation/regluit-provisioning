#!/usr/bin/env python3
"""Read-only: how deep do people page through /free/ (?work_list=N)?

Reads Apache logs in prod's combined_time format ("combined" + %D microseconds
last; regluit-provisioning roles/regluit_prod/templates/apache.conf.j2) and
reports GET /free/ requests by page depth for three traffic classes:

  likely-human  browser User-Agent AND Referer on unglue.it (people page by clicking)
  browser-only  browser User-Agent, no unglue.it Referer (includes spoofing scrapers)
  other         declared bots and non-browser clients

Prints counts only (no IPs, UAs or URLs). Args: log paths (.gz ok, '-' for
stdin) or YYYYMMDD dates (-> /var/log/apache2/YYYYMMDD_access.log, or .gz if
rotated).

Usage: ssh ubuntu@test.unglue.it 'python3 - 20260929 20260928' < scripts/page_depth.py
"""
import gzip
import os
import re
import sys
from urllib.parse import urlsplit, parse_qs

# Referer and User-Agent may contain \"-escaped quotes.
LINE = re.compile(
    r'^(\S+) \S+ \S+ \[[^\]]+\] "GET (\S+) [^"]*" (\d{3}) \S+ '
    r'"((?:[^"\\]|\\.)*)" "((?:[^"\\]|\\.)*)" (\d+)\s*$')
BOT = re.compile(r'bot|crawl|spider|slurp|scrap|fetch|python|curl|wget|java|go-http|'
                 r'httpclient|okhttp|axios|libwww|headless|externalagent|preview', re.I)
BROWSER = re.compile(r'^Mozilla/5\.0 .*(Chrome|Firefox|Safari|Edg)/')
OWN_REFERER = re.compile(r'^https?://(www\.|test\.)?unglue\.it/')
BUCKETS = [(1, 1), (2, 5), (6, 20), (21, 50), (51, 100), (101, None)]
CLASSES = ('likely-human', 'browser-only', 'other')


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


def page_of(query):
    # Same rule as el_pagination: missing or non-integer means page 1, and
    # 0 or negative is served as page 1. Django reads the last of repeated values.
    try:
        return max(1, int(parse_qs(query).get('work_list', ['1'])[-1]))
    except ValueError:
        return 1


def bucket_of(page):
    # Buckets are ascending, so the first that fits wins.
    for lo, hi in BUCKETS:
        if hi is None or page <= hi:
            return (lo, hi)


def classify(referer, ua):
    if BOT.search(ua) or not BROWSER.search(ua):
        return 'other'
    return 'likely-human' if OWN_REFERER.match(referer) else 'browser-only'


def main(args):
    if not args:
        sys.exit(__doc__)
    agg = {c: {b: {'n': 0, 'secs': 0.0, 'ips': set(), 'non200': 0} for b in BUCKETS}
           for c in CLASSES}
    human_depths = []
    parsed = skipped = 0
    for path in log_paths(args):
        with open_log(path) as fh:
            for line in fh:
                m = LINE.match(line)
                if not m:
                    skipped += 1
                    continue
                ip, url, status, referer, ua, micros = m.groups()
                try:
                    parts = urlsplit(url)
                except ValueError:  # e.g. an absolute-form target with a bad host
                    skipped += 1
                    continue
                parsed += 1
                if not parts.path.startswith('/free/') or parts.path.endswith('/marc/'):
                    continue
                page = page_of(parts.query)
                cls = classify(referer, ua)
                cell = agg[cls][bucket_of(page)]
                cell['n'] += 1
                cell['secs'] += int(micros) / 1e6
                cell['ips'].add(ip)
                cell['non200'] += status != '200'
                if cls == 'likely-human':
                    human_depths.append(page)

    print('files: %s' % ', '.join(log_paths(args)))
    print('log lines parsed %d, not matching format %d (non-GET lines count here)' % (parsed, skipped))
    total_secs = sum(c['secs'] for cls in agg.values() for c in cls.values()) or 1
    for cls in CLASSES:
        print('\n%s' % cls)
        print('  %-10s %8s %8s %9s %7s %8s' % ('page', 'requests', 'IPs', 'secs', 'share', 'non-200'))
        for (lo, hi), c in agg[cls].items():
            label = str(lo) if lo == hi else '%d-%s' % (lo, hi or 'up')
            print('  %-10s %8d %8d %9.0f %6.1f%% %8d' % (
                label, c['n'], len(c['ips']), c['secs'], 100 * c['secs'] / total_secs, c['non200']))
    if human_depths:
        d = sorted(human_depths)
        pct = lambda p: d[min(len(d) - 1, int(p * len(d)))]
        print('\nlikely-human depth: n=%d p50=%d p90=%d p99=%d p99.9=%d max=%d' % (
            len(d), pct(.5), pct(.9), pct(.99), pct(.999), d[-1]))
        print('likely-human requests deeper than 20/30/50/100: %d / %d / %d / %d' % tuple(
            sum(p > k for p in d) for k in (20, 30, 50, 100)))


if __name__ == '__main__':
    main(sys.argv[1:])
