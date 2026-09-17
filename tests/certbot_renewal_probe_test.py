#!/usr/bin/env python3
"""Cases for roles/regluit_prod/files/certbot_renewal_probe.py.

Runs the real script against hand-written renewal configs and checks the
effective webroot it reports for each domain. Every "must not pass" case here
came from a review round on regluit-provisioning#78 that found the previous,
regex-based check accepting a configuration certbot reads differently.

    python3 tests/certbot_renewal_probe_test.py            # uses this python3
    /path/to/python3 tests/certbot_renewal_probe_test.py   # pick another

Needs configobj importable, exactly as the target host does.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, os.pardir, 'roles', 'regluit_prod', 'files',
                     'certbot_renewal_probe.py')
OURS = '/var/lib/letsencrypt'

# (name, config text, domains, expected {domain: effective webroot}, expected authenticator)
CASES = [
    (
        "plain: map and path both ours",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/lib/letsencrypt,
[[webroot_map]]
test.unglue.it = /var/lib/letsencrypt
""",
        ['test.unglue.it'], {'test.unglue.it': OURS}, 'webroot',
    ),
    (
        "map wins over path (round 3)",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/lib/letsencrypt,
[[webroot_map]]
test.unglue.it = /var/www/html
""",
        ['test.unglue.it'], {'test.unglue.it': '/var/www/html'}, 'webroot',
    ),
    (
        "map wins, hidden behind an inline comment (round 4)",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/lib/letsencrypt,
[[webroot_map]]
test.unglue.it = /var/www/html # old webroot
""",
        ['test.unglue.it'], {'test.unglue.it': '/var/www/html'}, 'webroot',
    ),
    (
        "map wins, QUOTED KEY (round 5)",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/lib/letsencrypt,
[[webroot_map]]
"test.unglue.it" = /var/www/html
""",
        ['test.unglue.it'], {'test.unglue.it': '/var/www/html'}, 'webroot',
    ),
    (
        "one path containing a comma, quoted (round 5)",
        """[renewalparams]
authenticator = webroot
webroot_path = "/old,/var/lib/letsencrypt",
""",
        ['test.unglue.it'], {'test.unglue.it': '/old,/var/lib/letsencrypt'}, 'webroot',
    ),
    (
        "map wins, quoted value",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/lib/letsencrypt,
[[webroot_map]]
test.unglue.it = "/var/www/html"
""",
        ['test.unglue.it'], {'test.unglue.it': '/var/www/html'}, 'webroot',
    ),
    (
        "map value containing a space",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/lib/letsencrypt,
[[webroot_map]]
test.unglue.it = "/var/www/old html"
""",
        ['test.unglue.it'], {'test.unglue.it': '/var/www/old html'}, 'webroot',
    ),
    (
        "no map: falls back to webroot_path",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/lib/letsencrypt,
""",
        ['test.unglue.it'], {'test.unglue.it': OURS}, 'webroot',
    ),
    (
        "no map, stale webroot_path",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/www/html,
""",
        ['test.unglue.it'], {'test.unglue.it': '/var/www/html'}, 'webroot',
    ),
    (
        "multi-value webroot_path: last entry wins",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/www/html,/var/lib/letsencrypt,
""",
        ['test.unglue.it'], {'test.unglue.it': OURS}, 'webroot',
    ),
    (
        "prefix lookalike is not ours",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/lib/letsencrypt-old,
""",
        ['test.unglue.it'], {'test.unglue.it': '/var/lib/letsencrypt-old'}, 'webroot',
    ),
    (
        "apache plugin, not webroot",
        """[renewalparams]
authenticator = apache
[[webroot_map]]
test.unglue.it = /var/lib/letsencrypt
""",
        ['test.unglue.it'], {'test.unglue.it': OURS}, 'apache',
    ),
    (
        "authenticator hidden behind an inline comment",
        """[renewalparams]
authenticator = apache # was webroot
webroot_path = /var/lib/letsencrypt,
""",
        ['test.unglue.it'], {'test.unglue.it': OURS}, 'apache',
    ),
    (
        "both names mapped to ours",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/lib/letsencrypt,
[[webroot_map]]
unglue.it = /var/lib/letsencrypt
www.unglue.it = /var/lib/letsencrypt
""",
        ['unglue.it', 'www.unglue.it'],
        {'unglue.it': OURS, 'www.unglue.it': OURS}, 'webroot',
    ),
    (
        "alt name mapped elsewhere",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/lib/letsencrypt,
[[webroot_map]]
unglue.it = /var/lib/letsencrypt
www.unglue.it = /var/www/html
""",
        ['unglue.it', 'www.unglue.it'],
        {'unglue.it': OURS, 'www.unglue.it': '/var/www/html'}, 'webroot',
    ),
    (
        "alt name unmapped, stale path behind it",
        """[renewalparams]
authenticator = webroot
webroot_path = /var/www/html,
[[webroot_map]]
unglue.it = /var/lib/letsencrypt
""",
        ['unglue.it', 'www.unglue.it'],
        {'unglue.it': OURS, 'www.unglue.it': '/var/www/html'}, 'webroot',
    ),
    (
        "no webroot_path line at all",
        """[renewalparams]
authenticator = webroot
""",
        ['test.unglue.it'], {'test.unglue.it': ''}, 'webroot',
    ),
    (
        "no renewalparams section at all",
        """version = 2.9.0
""",
        ['test.unglue.it'], {'test.unglue.it': ''}, '',
    ),
]


def run_probe(python, text, domains):
    with tempfile.NamedTemporaryFile('w', suffix='.conf', delete=False) as fh:
        fh.write(text)
        path = fh.name
    try:
        proc = subprocess.run([python, PROBE, path] + domains,
                              capture_output=True, text=True)
    finally:
        os.unlink(path)
    if proc.returncode != 0:
        raise AssertionError("probe exited %d: %s" % (proc.returncode, proc.stderr.strip()))
    authenticator = ''
    webroots = {}
    for line in proc.stdout.splitlines():
        if line.startswith('authenticator='):
            authenticator = line.split('=', 1)[1]
        elif line.startswith('webroot='):
            domain, _, root = line[len('webroot='):].partition(' ')
            webroots[domain] = root
    return authenticator, webroots


def main():
    python = sys.argv[1] if len(sys.argv) > 1 else sys.executable
    failures = 0
    for name, text, domains, expect_roots, expect_auth in CASES:
        try:
            auth, roots = run_probe(python, text, domains)
        except AssertionError as exc:
            print("FAIL  %-48s %s" % (name, exc))
            failures += 1
            continue
        ok = (auth == expect_auth and roots == expect_roots)
        # the check the playbook makes, shown so the intent is visible
        accepted = (auth == 'webroot'
                    and all(roots.get(d) == OURS for d in domains))
        print("%-5s %-48s authenticator=%-8s accepted=%-5s %s"
              % ("ok" if ok else "FAIL", name, auth or '(none)', accepted, roots))
        if not ok:
            print("      expected authenticator=%r roots=%r" % (expect_auth, expect_roots))
            failures += 1
    print("\n%d case(s) failed out of %d" % (failures, len(CASES)))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
