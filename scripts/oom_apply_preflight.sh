#!/usr/bin/env bash
# OOM apply pre-flight + rollback staging.  regluit-provisioning#45
#
# Run this as the FIRST step of the OOM daemon-mode apply, BEFORE ansible.
# On the target host it:
#   1. backs up the live apache config (/etc/apache2/sites-available/prod.conf)
#      and the root crontab, timestamped (UTC);
#   2. baseline `apache2ctl configtest`;
#   3. stages /root/oom_rollback.sh so reversal is ONE command.
#
# Reversal (if the apply goes haywire):   sudo /root/oom_rollback.sh
#   -> restores the latest pre-apply apache config + root crontab, validates,
#      restarts apache (back to embedded mode). swap + mem-alert are left in
#      place (harmless). The band-aid restart cron is restored with the crontab.
#
# Usage:  ./scripts/oom_apply_preflight.sh <host>
#   e.g.  ./scripts/oom_apply_preflight.sh test.unglue.it     # rehearse
#         ./scripts/oom_apply_preflight.sh unglue.it          # prod
set -euo pipefail
HOST="${1:?usage: $0 <host>   e.g. unglue.it | test.unglue.it}"
KEY="${KEY:-/Volumes/ryvault1/gluejar/EC2_Keys/production.pem}"

ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "ubuntu@$HOST" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
ts=$(date -u +%Y%m%dT%H%M%SZ)
CONF=/etc/apache2/sites-available/prod.conf

echo "== pre-flight backups (ts=$ts) on $(hostname) =="
cp -a "$CONF" "$CONF.bak.$ts"
crontab -l -u root > "/root/root.crontab.bak.$ts" 2>/dev/null || :
apache2ctl configtest
echo "  apache  -> $CONF.bak.$ts"
echo "  crontab -> /root/root.crontab.bak.$ts"

echo "== staging /root/oom_rollback.sh =="
cat > /root/oom_rollback.sh <<'RB'
#!/usr/bin/env bash
# One-command OOM rollback. Restores the LATEST pre-apply apache config + root
# crontab, validates, and restarts apache (back to embedded mode).
# swap + mem-alert are left in place (harmless). See regluit-provisioning#45.
set -euo pipefail
CONF=/etc/apache2/sites-available/prod.conf
conf_bak=$(ls -t "$CONF".bak.* 2>/dev/null | head -1)
cron_bak=$(ls -t /root/root.crontab.bak.* 2>/dev/null | head -1)
[ -n "${conf_bak:-}" ] || { echo "FATAL: no $CONF.bak.* backup found"; exit 1; }
echo ">> restoring apache config: $conf_bak"
cp -a "$conf_bak" "$CONF"
apache2ctl configtest
systemctl restart apache2
if [ -n "${cron_bak:-}" ]; then
  echo ">> restoring root crontab (re-enables band-aid restart cron): $cron_bak"
  crontab -u root "$cron_bak"
fi
echo ">> apache active? $(systemctl is-active apache2)"
echo ">> wsgi daemon procs (expect 0 = embedded after rollback): $(ps aux | grep -c '[(]wsgi:regluit[)]')"
echo ">> ROLLBACK COMPLETE. Verify externally: curl -I https://$(hostname -f)/ (expect 200)"
RB
chmod 700 /root/oom_rollback.sh

echo
echo "PRE-FLIGHT DONE on $(hostname)."
echo "ROLLBACK IS ONE COMMAND:   sudo /root/oom_rollback.sh"
REMOTE
