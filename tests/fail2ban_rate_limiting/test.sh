#!/bin/bash
# Host-side wrapper: renders the fail2ban jail + filter templates with default
# values and runs the assertion harness (run_tests.sh) inside ubuntu:24.04 with
# the real fail2ban package. Usage: ./test.sh   (requires docker)
#
# NET_ADMIN is granted so the REAL iptables ban action runs and the test can
# assert the actual firewall rule, not just fail2ban's opinion of it. It affects
# the container's own network namespace only. The container is `docker run --rm`:
# nothing persists, nothing to tear down.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
TPL="$HERE/../../roles/regluit_prod/templates/fail2ban"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/filter.d" "$WORK/jail.d"
for f in regluit-flood regluit-expensive regluit-badbot; do
    cp "$TPL/$f.conf.j2" "$WORK/filter.d/$f.conf"      # no Jinja in the filters
done

# Render the jail the way group_vars/production would: alerts on, no extra
# ignoreip. The {% if %} branch taken here is the one production takes.
python3 - "$TPL/jail-regluit.conf.j2" "$WORK/jail.d/regluit-rate-limit.conf" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
s = s.replace("{{ (' ' ~ rate_limit_ignoreips) if rate_limit_ignoreips | default('') else '' }}", "")
s = s.replace("{{ mem_alert_email | default('notices@gluejar.com') }}", "notices@gluejar.com")
s = s.replace("{{ default_from_email | default('notices@gluejar.com') }}", "notices@gluejar.com")
s = re.sub(r"\{%\s*if monitoring_alerts_enabled[^%]*%\}\n", "", s)          # alerts ON branch
s = re.sub(r"\{%\s*else\s*%\}\n.*?\{%\s*endif\s*%\}\n", "", s, flags=re.S)
assert "{{" not in s and "{%" not in s, "unrendered Jinja left in jail file"
open(dst, "w").write(s)
PY

cp "$HERE/run_tests.sh" "$WORK/run_tests.sh"
docker run --rm --cap-add=NET_ADMIN -v "$WORK":/work ubuntu:24.04 bash /work/run_tests.sh
