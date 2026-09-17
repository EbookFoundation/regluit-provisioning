#!/usr/bin/env python3
"""Report a certbot lineage's effective renewal settings, read-only.

Used by roles/regluit_prod/tasks/certs_precheck.yml to check that a host's
stored renewal settings agree with the ACME challenge Alias that
apache.conf.j2 writes. Reading the file with certbot's own parser --
ConfigObj, which the certbot package depends on -- rather than matching
patterns against the text, because the format has quoted keys, quoted values,
inline comments, list values and commas inside quoted values, and a hand-
written parser kept accepting configurations certbot reads differently
(review rounds 3-5 on regluit-provisioning#78).

    certbot_renewal_probe.py <renewal.conf> <domain> [<domain> ...]

Prints `key=value` lines for the caller to parse, and exits 0 even when the
answer is "no certificate settings here" -- judging the result is the
playbook's job, not this script's. A non-zero exit means the file could not be
read or parsed at all.

    authenticator=webroot
    webroot=<domain> <effective webroot, or empty>

The effective webroot for a domain is its own [[webroot_map]] entry when the
config has one, and otherwise the LAST entry of webroot_path -- which is how
certbot's webroot plugin resolves it.
"""
import sys


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: %s <renewal.conf> <domain> [...]\n" % argv[0])
        return 2

    try:
        from configobj import ConfigObj
    except ImportError:
        sys.stderr.write(
            "configobj is not importable by this python3. It ships as a "
            "dependency of the certbot package, so a certbot host should "
            "have it; install python3-configobj.\n")
        return 3

    path, domains = argv[1], argv[2:]
    try:
        conf = ConfigObj(path, file_error=True)
    except Exception as exc:                      # unreadable or malformed
        sys.stderr.write("cannot parse %s: %s\n" % (path, exc))
        return 4

    # Report exactly what ConfigObj returns, with no tidying. Anything this
    # script normalises that certbot does not makes the check MORE permissive
    # than reality: `test.unglue.it = "/var/lib/letsencrypt "` is a different
    # directory to certbot, and `webroot_path = /a, ""` really does select the
    # empty last entry. Both slipped through an earlier version of this script
    # that stripped whitespace and dropped empty entries (review round 6).
    # A value ConfigObj returns as a list prints as a list and therefore fails
    # the playbook's equality check, which is the safe direction.
    params = conf.get('renewalparams') or {}

    authenticator = params.get('authenticator', '')
    webroot_map = params.get('webroot_map') or {}
    webroot_path = params.get('webroot_path', '')

    # `webroot_path = /a,/b,` is a list to ConfigObj; `"/a,/b",` is one entry.
    # certbot's webroot plugin falls back to the LAST entry.
    if isinstance(webroot_path, (list, tuple)):
        webroot_path = webroot_path[-1] if webroot_path else ''

    print("authenticator=%s" % (authenticator,))
    for domain in domains:
        print("webroot=%s %s" % (domain, webroot_map.get(domain, webroot_path)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
