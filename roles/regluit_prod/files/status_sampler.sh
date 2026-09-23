#!/bin/bash
# status_sampler.sh -- one line per minute of "how busy is this box, and where"
# (EbookFoundation/security-private#33).
#
# Production has refused traffic three times (8/30, 9/2, 9/23) while the
# machine sat idle, and each time the diagnosis stayed an inference because
# nothing recorded Apache's worker state or the database connections at the
# time. This records both, so the next episode is measured.
#
# Read-only: it queries Apache's own status page over loopback and counts
# established MySQL connections. It sends no mail and restarts nothing.
# Runs as the unprivileged app user, NOT root: /var/log/regluit is
# group-writable by www-data, and a root script appending there could be
# pointed at any file via a symlink. Nothing here needs root.
# Output: /var/log/regluit/status_sampler/YYYYMMDD.log (UTC), one line per run:
#   2026-09-23T20:15:00Z busy=12 idle=138 sb_R=1 sb_W=9 sb_K=2 sb_C=0 sb_G=0 db_conns=4 load1=0.05
# If the status page does not answer within 5s the line says
# apache_status=unavailable -- during an outage that is itself the signal.
# Retention: the existing 30-day cleanup of /var/log/regluit/*.log (cron.yml).
set -u
SERVER_NAME="${1:?usage: status_sampler.sh <server_name>}"
OUT_DIR=/var/log/regluit/status_sampler

# Never let two runs overlap (a hung curl must not pile up processes).
exec 9>/run/lock/status_sampler.lock
flock -n 9 || exit 0

mkdir -p "$OUT_DIR"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

apache="apache_status=unavailable"
# Only a complete, successful response counts; a timed-out partial body must
# not be recorded as zeros. (The probe itself normally shows as one busy 'W'.)
if status=$(timeout 8 curl -sk --fail --max-time 5 --noproxy '*' \
        --resolve "${SERVER_NAME}:443:127.0.0.1" \
        "https://${SERVER_NAME}/server-status?auto" 2>/dev/null); then
    field() { printf '%s\n' "$status" | awk -F': ' -v k="$1" '$1 == k {print $2; exit}'; }
    busy=$(field BusyWorkers); idle=$(field IdleWorkers); sb=$(field Scoreboard)
    if [[ "$busy" =~ ^[0-9]+$ && "$idle" =~ ^[0-9]+$ && -n "$sb" ]]; then
        # Scoreboard letters: R reading request, W sending reply, K keepalive,
        # C closing, G gracefully finishing. '_' idle and '.' open slot are
        # implied by busy/idle.
        count() { printf '%s' "$sb" | tr -cd "$1" | wc -c | tr -d ' '; }
        apache="busy=$busy idle=$idle sb_R=$(count R) sb_W=$(count W) sb_K=$(count K) sb_C=$(count C) sb_G=$(count G)"
    fi
fi

# Established TCP connections to port 3306 (the app's MySQL/RDS; nothing else
# on these hosts uses that port, but ss cannot prove whose they are). With
# Django's CONN_MAX_AGE at 0 a connection is held for the length of a request,
# so a count that stays high while traffic is low points at slow queries.
# NA if ss itself fails, rather than a misleading 0.
if ssout=$(ss -Htn state established '( dport = :3306 )' 2>/dev/null); then
    db=$(printf '%s' "$ssout" | grep -c .)
else
    db=NA
fi
load=$(cut -d' ' -f1 /proc/loadavg)

echo "$ts $apache db_conns=$db load1=$load" >> "$OUT_DIR/$(date -u +%Y%m%d).log"
