#!/usr/bin/env bash
# describe_prod.sh - read-only description of a regluit server, for comparing
# what the playbooks would build against what is actually running.
#
# Usage (from the control machine; nothing is copied to the server). The one
# argument is the host's server_name (default unglue.it), used for the
# certificate paths:
#   ssh ubuntu@unglue.it 'bash -s' < scripts/describe_prod.sh > prod.describe.txt
#   ssh ubuntu@test.unglue.it 'bash -s -- test.unglue.it' < scripts/describe_prod.sh > test.describe.txt
#   diff prod.describe.txt built.describe.txt
#
# What it prints, and what it never prints:
#   - For the files and directories the regluit_prod role renders or installs
#     (the main ones, listed below; not every piece of state the role touches):
#     exists?, owner:group, mode, and the first 16 hex chars of its sha256.
#     NEVER the contents. Several hold credentials (settings/prod.py,
#     settings/keys/host.py, deploy/prod.wsgi, ~/.my.cnf); a truncated hash
#     cannot be turned back into them, but treat the output as internal and do
#     not post it publicly.
#   - Private key files (TLS) are checked for existence only; they are not read.
#   - Cron entries: the "#Ansible:" marker names plus a hash of each job line,
#     not the line itself.
#   - Versions, enabled apache modules/sites, systemd unit states, the app's
#     deployed commit and branch, a hash of `pip freeze`.
#   - Any command that fails prints ERROR in place of a value, so a failure can
#     never look like a healthy result.
#
# Read-only: no writes, no restarts, no package operations; git runs with
# --no-optional-locks so `git status` does not refresh the index. Uses sudo
# only to read (stat/sha256sum/crontab -l) files the ubuntu user cannot.
# Output is deterministic (sorted, no timestamps) so two runs can be diffed.

set -u
set -o pipefail
export LC_ALL=C

SERVER_NAME="${1:-unglue.it}"

h() { local out; out=$(sudo sha256sum "$1" 2>/dev/null) && echo "${out:0:16}" || echo ERROR; }
# Run a command; print its output, or ERROR if it fails or prints nothing.
v() { local out; out=$("$@" 2>/dev/null) && [ -n "$out" ] && echo "$out" || echo ERROR; }

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
echo "python3 $(v python3 -c 'import platform; print(platform.python_version())')"
echo "venv_python $(v $P/venv/bin/python -c 'import platform; print(platform.python_version())')"
echo "swap_total_mb $(free -m | awk '/^Swap:/{print $2}')"

echo "swapfile $(sudo test -e /swapfile && echo present || echo absent)"
echo "fstab $(h /etc/fstab)"

G="git --no-optional-locks -C $P"
echo "## app"
echo "app_commit $(v $G rev-parse HEAD)"
echo "app_branch $(v $G rev-parse --abbrev-ref HEAD)"
if st=$($G status --porcelain 2>/dev/null); then
  echo "app_dirty_files $(printf '%s' "$st" | grep -c . || true)"
else
  echo "app_dirty_files ERROR"
fi
if fr=$($P/venv/bin/pip freeze 2>/dev/null) && [ -n "$fr" ]; then
  echo "pip_freeze $(printf '%s\n' "$fr" | sort | sha256sum | cut -c1-16) count=$(printf '%s\n' "$fr" | wc -l | tr -d ' ')"
else
  echo "pip_freeze ERROR"
fi

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
for d in /var/www/static /var/www/maintenance /var/log/regluit /var/log/celery $P/.lock; do
  if sudo test -d "$d"; then printf 'dir %s %s\n' "$d" "$(sudo stat -c '%U:%G %a' "$d")"; else printf 'dir %s MISSING\n' "$d"; fi
done
echo "maintenance_flag $(sudo test -e /var/www/maintenance/MAINTENANCE_ON && echo ON || echo off)"

echo "## certificates (existence only; keys are not read)"
exists_only "/etc/letsencrypt/live/$SERVER_NAME/fullchain.pem"
exists_only "/etc/letsencrypt/live/$SERVER_NAME/privkey.pem"

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
