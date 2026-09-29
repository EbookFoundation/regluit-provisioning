#!/usr/bin/env bash
# describe_prod.sh - read-only description of a regluit server, for comparing
# what the playbooks would build against what is actually running.
#
# Usage (from the control machine; nothing is copied to the server):
#   ssh ubuntu@unglue.it 'bash -s' < scripts/describe_prod.sh > prod.describe.txt
#   ssh ubuntu@test.unglue.it 'bash -s' < scripts/describe_prod.sh > test.describe.txt
#   diff prod.describe.txt built.describe.txt
#
# What it prints, and what it never prints:
#   - For each file the regluit_prod role manages: exists?, owner:group, mode,
#     and the first 16 hex chars of its sha256. NEVER the contents. Several of
#     these files hold credentials (settings/prod.py, settings/keys/host.py,
#     deploy/prod.wsgi, ~/.my.cnf); a truncated hash reveals nothing usable.
#   - Private key files (TLS) are checked for existence only; they are not read.
#   - Cron entries: the "#Ansible:" marker names plus a hash of each job line,
#     not the line itself.
#   - Versions, enabled apache modules/sites, systemd unit states, the app's
#     deployed commit and branch, a hash of `pip freeze`.
#
# Changes nothing: no writes, no restarts, no package operations. Uses sudo
# only to read (stat/sha256sum/crontab -l) files the ubuntu user cannot.
# Output is deterministic (sorted, no timestamps) so two runs can be diffed.

set -u
export LC_ALL=C

h() { sudo sha256sum "$1" 2>/dev/null | cut -c1-16; }

describe_file() {
  local p="$1"
  if sudo test -e "$p"; then
    printf 'file %s %s %s\n' "$p" "$(sudo stat -c '%U:%G %a' "$p")" "$(h "$p")"
  else
    printf 'file %s MISSING\n' "$p"
  fi
}

exists_only() {
  local p="$1"
  if sudo test -e "$p"; then printf 'exists %s yes\n' "$p"; else printf 'exists %s MISSING\n' "$p"; fi
}

PY=3.12   # python_version in group_vars; the venv check below reports the real one
P=/opt/regluit

echo "## system"
echo "os $(. /etc/os-release && echo "$VERSION_ID")"
echo "python3 $(python3 --version 2>&1 | awk '{print $2}')"
echo "venv_python $($P/venv/bin/python --version 2>&1 | awk '{print $2}')"
echo "swap_total_mb $(free -m | awk '/^Swap:/{print $2}')"

echo "## app"
echo "app_commit $(git -C $P rev-parse HEAD 2>/dev/null || echo NONE)"
echo "app_branch $(git -C $P rev-parse --abbrev-ref HEAD 2>/dev/null || echo NONE)"
echo "app_dirty_files $(git -C $P status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "pip_freeze $($P/venv/bin/pip freeze 2>/dev/null | sort | sha256sum | cut -c1-16) count=$($P/venv/bin/pip freeze 2>/dev/null | wc -l | tr -d ' ')"

echo "## managed files"
for f in \
  /etc/apache2/sites-available/prod.conf \
  /var/www/maintenance/maintenance.html \
  /etc/default/celeryd /etc/default/celerybeat \
  /etc/systemd/system/celeryd.service /etc/systemd/system/celerybeat.service \
  /etc/apt/apt.conf.d/51-automatic-reboot \
  /etc/systemd/journald.conf.d/size-limit.conf \
  /etc/letsencrypt/renewal-hooks/deploy/reload-apache.sh \
  /usr/local/sbin/apache_liveness_watch.sh /usr/local/sbin/mem_alert.sh \
  /usr/local/sbin/status_sampler.sh /usr/local/sbin/wsgi_wedge_watch.sh \
  /home/ubuntu/setup.sh /home/ubuntu/dump.sh /home/ubuntu/.my.cnf \
  $P/deploy/prod.wsgi $P/settings/prod.py \
  $P/settings/keys/__init__.py $P/settings/keys/common.py $P/settings/keys/host.py \
  $P/venv/lib/python$PY/site-packages/regluit.pth \
  $P/venv/lib/python$PY/site-packages/opt.pth ; do
  describe_file "$f"
done

echo "## directories"
for d in /var/www/static /var/www/maintenance /var/log/regluit /var/log/celery; do
  if sudo test -d "$d"; then printf 'dir %s %s\n' "$d" "$(sudo stat -c '%U:%G %a' "$d")"; else printf 'dir %s MISSING\n' "$d"; fi
done
echo "maintenance_flag $(sudo test -e /var/www/maintenance/MAINTENANCE_ON && echo ON || echo off)"

echo "## certificates (existence only; keys are not read)"
exists_only /etc/letsencrypt/live/unglue.it/fullchain.pem
exists_only /etc/letsencrypt/live/unglue.it/privkey.pem

echo "## apache"
echo "mods_enabled $(ls /etc/apache2/mods-enabled/ 2>/dev/null | sed -n 's/\.load$//p' | sort | tr '\n' ' ')"
echo "sites_enabled $(ls /etc/apache2/sites-enabled/ 2>/dev/null | sort | tr '\n' ' ')"
echo "apache_version $(apache2 -v 2>/dev/null | awk -F'[/ ]' '/version/{print $4}')"
echo "mod_wsgi_pkg $(dpkg-query -W -f='${Version}' libapache2-mod-wsgi-py3 2>/dev/null || echo NONE)"

echo "## systemd units"
for u in apache2 celeryd celerybeat redis-server cron postfix unattended-upgrades; do
  echo "unit $u enabled=$(systemctl is-enabled $u 2>/dev/null || true) active=$(systemctl is-active $u 2>/dev/null || true)"
done

echo "## cron (marker names + job-line hashes, never the line)"
for u in root ubuntu; do
  sudo crontab -l -u "$u" 2>/dev/null | awk -v u="$u" '
    /^#Ansible: /{name=substr($0,11); next}
    /^[[:space:]]*$/{next}
    {line=$0;
     disabled = (line ~ /^#/) ? "disabled" : "enabled";
     print u "\t" (name==""?"(unmanaged)":name) "\t" disabled "\t" line; name=""}' \
  | while IFS=$'\t' read -r user name state line; do
      printf 'cron %s %s %s %s\n' "$user" "$name" "$state" "$(printf '%s' "$line" | sha256sum | cut -c1-16)"
    done
done | sort

echo "## key packages"
for pkg in apache2 redis-server default-mysql-client python3.12 cronolog certbot; do
  echo "pkg $pkg $(dpkg-query -W -f='${Version}' $pkg 2>/dev/null || echo NONE)"
done
