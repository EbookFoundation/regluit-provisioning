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

    params = conf.get('renewalparams') or {}
    authenticator = params.get('authenticator') or ''
    if isinstance(authenticator, list):           # not expected; be tolerant
        authenticator = authenticator[-1] if authenticator else ''

    webroot_map = params.get('webroot_map') or {}

    # `webroot_path = /a,/b,` is a list to ConfigObj; `"/a,/b",` is one entry.
    webroot_path = params.get('webroot_path') or ''
    if isinstance(webroot_path, (list, tuple)):
        entries = [str(p).strip() for p in webroot_path if str(p).strip()]
        webroot_path = entries[-1] if entries else ''
    else:
        webroot_path = str(webroot_path).strip()

    print("authenticator=%s" % authenticator)
    for domain in domains:
        effective = webroot_map.get(domain, webroot_path)
        if isinstance(effective, (list, tuple)):
            effective = effective[-1] if effective else ''
        print("webroot=%s %s" % (domain, str(effective).strip()))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
