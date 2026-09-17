#!/bin/bash
# Test harness for apache_liveness_watch.sh — runs inside an ubuntu container.
# Mocks: curl, systemctl, logger, ss (PATH shims) + /usr/sbin/sendmail.
# Real: bash, flock, awk, tail, date.
#
# No date mocking: cooldown/cap/pruning are exercised by writing timestamps
# straight into the state directory, which is what the script actually reads.
set -u
cd /work
export EVID=/work/evidence
export CTL=/work/ctl
mkdir -p mockbin "$EVID" "$CTL"
STATE=/run/apache_liveness

# ---- mocks ----
cat > mockbin/curl <<'EOF'
#!/bin/bash
# Probe A is the only http:// call; probe B is the https:// one.
case "$*" in
  *https://*) echo "B $*" >> "$EVID/curl_calls"; printf '%s' "$(cat $CTL/b_code)"; exit "$(cat $CTL/b_rc)" ;;
  *)          echo "A $*" >> "$EVID/curl_calls"; printf '%s' "$(cat $CTL/a_code)"; exit "$(cat $CTL/a_rc)" ;;
esac
EOF
cat > mockbin/systemctl <<'EOF'
#!/bin/bash
echo "SYSTEMCTL $*" >> "$EVID/systemctl"
exit "$(cat $CTL/restart_rc)"
EOF
cat > mockbin/logger <<'EOF'
#!/bin/bash
# Record a message given as arguments; otherwise record piped stdin verbatim.
msg=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-t" ]; then shift; shift; else msg="$msg $1"; shift; fi
done
if [ -n "$msg" ]; then echo "LOGGER$msg" >> "$EVID/logger"; else cat >> "$EVID/logger"; fi
EOF
cat > mockbin/ss <<'EOF'
#!/bin/bash
echo "LISTEN 511 511 *:80 *:*"
echo "LISTEN 511 511 *:443 *:*"
EOF
chmod +x mockbin/*
mkdir -p /usr/sbin /var/log/apache2
cat > /usr/sbin/sendmail <<'EOF'
#!/bin/bash
cat >> "$EVID/mail"
exit "$(cat $CTL/sendmail_rc)"
EOF
chmod +x /usr/sbin/sendmail
echo "[Thu Sep 17 20:35:01 2026] [mpm_event:error] AH00484: server reached MaxRequestWorkers" \
    > /var/log/apache2/error.log

pass=0; fail=0
assert() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

# setup <a_code> <a_rc> <b_code> <b_rc> — fresh state, fresh evidence
setup() {
    rm -rf "$STATE" "$EVID"; mkdir -p "$EVID" "$STATE"
    echo "$1" > $CTL/a_code; echo "$2" > $CTL/a_rc
    echo "$3" > $CTL/b_code; echo "$4" > $CTL/b_rc
    echo 0 > $CTL/restart_rc; echo 0 > $CTL/sendmail_rc
}
run() { PATH=/work/mockbin:$PATH bash /work/watch.sh; echo $?; }

echo "--- 1. healthy: apache 301, app 200 ---"
setup 301 0 200 0
RC=$(run)
assert "healthy: exit 0"                 "[ $RC -eq 0 ]"
assert "healthy: no restart"             "[ ! -f $EVID/systemctl ]"
assert "healthy: no mail"                "[ ! -f $EVID/mail ]"
assert "healthy: no failure counter"     "[ ! -f $STATE/fail_a ]"
assert "healthy: both probes ran"        "[ \$(wc -l < $EVID/curl_calls) -eq 2 ]"
assert "probe A hits 127.0.0.1 on :80"   "grep -q 'A .*http://127.0.0.1/' $EVID/curl_calls"
assert "probe B resolves to loopback"    "grep -q 'B .*--resolve unglue.it:443:127.0.0.1' $EVID/curl_calls"

echo "--- 2. maintenance mode: app returns 503 ---"
setup 301 0 503 0
run > /dev/null
assert "503 is not an app failure"       "[ ! -f $STATE/fail_b ] && [ ! -f $EVID/mail ]"

echo "--- 3. first apache failure: count, do not act ---"
setup 000 28 200 0
RC=$(run)
assert "1st failure: exit 0"             "[ $RC -eq 0 ]"
assert "1st failure: counter is 1"       "[ \$(cat $STATE/fail_a) -eq 1 ]"
assert "1st failure: no restart"         "[ ! -f $EVID/systemctl ]"
assert "1st failure: probe B not run"    "! grep -q '^B ' $EVID/curl_calls"

echo "--- 4. third consecutive failure: restart ---"
setup 000 28 200 0
echo 2 > $STATE/fail_a
run > /dev/null
assert "3rd failure: apache restarted"   "grep -q 'SYSTEMCTL restart apache2' $EVID/systemctl"
assert "3rd failure: mail sent"          "grep -q 'Subject: .*apache restarted by liveness watchdog' $EVID/mail"
assert "mail names the exit code"        "grep -q 'exited 0' $EVID/mail"
assert "evidence: listen queues"         "grep -q '\*:443' $EVID/mail"
assert "evidence: apache error log tail" "grep -q 'AH00484' $EVID/mail"
assert "evidence also went to syslog"    "grep -q 'AH00484' $EVID/logger"
assert "one restart recorded"            "[ \$(wc -l < $STATE/restarts) -eq 1 ]"

echo "--- 5. cooldown blocks a second restart ---"
setup 000 28 200 0
echo 5 > $STATE/fail_a; date -d '100 seconds ago' +%s > $STATE/restarts
run > /dev/null
assert "cooldown: no restart"            "[ ! -f $EVID/systemctl ]"
assert "cooldown: no mail"               "[ ! -f $EVID/mail ]"
assert "cooldown: logged"                "grep -q 'cooldown' $EVID/logger"

echo "--- 6. cap reached: stop and shout ---"
setup 000 28 200 0
echo 9 > $STATE/fail_a
for s in 1000 2000 3000; do date -d "$s seconds ago" +%s >> $STATE/restarts; done
run > /dev/null
assert "cap: no restart"                 "[ ! -f $EVID/systemctl ]"
assert "cap: escalation mail"            "grep -q 'Subject: .*NOT restarting (cap reached)' $EVID/mail"
assert "cap: latched"                    "[ -f $STATE/capped ]"

echo "--- 7. latched: no further restart, no repeat mail (still logs) ---"
rm -f $EVID/mail $EVID/systemctl
run > /dev/null
assert "latched: still no restart"       "[ ! -f $EVID/systemctl ]"
assert "latched: no repeat mail"         "[ ! -f $EVID/mail ]"
assert "latched: still logging"          "grep -q 'probe A failed' $EVID/logger"

echo "--- 8. recovery clears the latch but NOT the restart budget ---"
echo 301 > $CTL/a_code; echo 0 > $CTL/a_rc
run > /dev/null
assert "recovery: latch cleared"         "[ ! -f $STATE/capped ]"
assert "recovery: counter cleared"       "[ ! -f $STATE/fail_a ]"
assert "recovery: budget NOT refilled"   "[ \$(wc -l < $STATE/restarts) -eq 3 ]"

echo "--- 9. restarts older than an hour are pruned ---"
setup 000 28 200 0
echo 5 > $STATE/fail_a
for s in 4000 5000 6000; do date -d "$s seconds ago" +%s >> $STATE/restarts; done
run > /dev/null
assert "pruned: restart allowed again"   "grep -q 'SYSTEMCTL restart apache2' $EVID/systemctl"
assert "pruned: budget now holds 1"      "[ \$(wc -l < $STATE/restarts) -eq 1 ]"

echo "--- 10. app down while apache is alive: alert only, once ---"
setup 301 0 500 0
echo 4 > $STATE/fail_b
run > /dev/null
assert "app down: no restart"            "[ ! -f $EVID/systemctl ]"
assert "app down: alert mail"            "grep -q 'Subject: .*app not answering' $EVID/mail"
assert "app down: says no restart done"  "grep -q 'NO RESTART WAS PERFORMED' $EVID/mail"
rm -f $EVID/mail
run > /dev/null
assert "app down: not alerted twice"     "[ ! -f $EVID/mail ]"

echo "--- 11. app slow but under threshold: silent ---"
setup 301 0 000 28
run > /dev/null
assert "app 1 failure: no mail"          "[ ! -f $EVID/mail ] && [ \$(cat $STATE/fail_b) -eq 1 ]"

echo "--- 12. sendmail failure does not set the dedup flag ---"
setup 301 0 500 0
echo 4 > $STATE/fail_b; echo 1 > $CTL/sendmail_rc
run > /dev/null
assert "mail failed: no dedup flag"      "[ ! -f $STATE/b_alerted ]"
assert "mail failed: logged"             "grep -q 'sendmail failed' $EVID/logger"

echo "--- 13. malformed state files read as zero, not as a crash ---"
setup 000 28 200 0
printf 'garbage' > $STATE/fail_a
printf '08\n'    > $STATE/fail_b
printf '%s junk\nnot-a-number\n' "$(date -d '30 seconds ago' +%s)" > $STATE/restarts
RC=$(run)
assert "malformed: exit 0"               "[ $RC -eq 0 ]"
assert "malformed counter restarts at 1" "[ \$(cat $STATE/fail_a) -eq 1 ]"
assert "malformed: no restart at 1/3"    "[ ! -f $EVID/systemctl ]"
echo 2 > $STATE/fail_a
run > /dev/null
assert "malformed restarts: cooldown won" "[ ! -f $EVID/systemctl ]"
assert "malformed restarts: pruned clean" "! grep -q junk $STATE/restarts"

echo "--- 14. failed restart still counts, and says so ---"
setup 000 28 200 0
echo 2 > $STATE/fail_a; echo 1 > $CTL/restart_rc
run > /dev/null
assert "failed restart: attempt counted" "[ \$(wc -l < $STATE/restarts) -eq 1 ]"
assert "failed restart: says attempted"  "grep -q 'A restart was attempted' $EVID/mail"
assert "failed restart: reports rc 1"    "grep -q 'exited 1' $EVID/mail"

echo "--- 15. undelivered cap alert is retried, restart stays barred ---"
setup 000 28 200 0
echo 9 > $STATE/fail_a; echo 1 > $CTL/sendmail_rc
for s in 1000 2000 3000; do date -d "$s seconds ago" +%s >> $STATE/restarts; done
run > /dev/null
assert "cap mail failed: not flagged"    "[ -f $STATE/capped ] && [ ! -f $STATE/cap_alerted ]"
rm -f $EVID/mail; echo 0 > $CTL/sendmail_rc
run > /dev/null
assert "cap mail retried next run"       "grep -q 'NOT restarting (cap reached)' $EVID/mail"
assert "cap mail then flagged"           "[ -f $STATE/cap_alerted ]"
assert "cap retry: still no restart"     "[ ! -f $EVID/systemctl ]"
rm -f $EVID/mail
run > /dev/null
assert "cap mail not sent a third time"  "[ ! -f $EVID/mail ]"

echo "--- 16. non-zero curl exit counts as a failure even with a status code ---"
setup 301 18 200 0
run > /dev/null
assert "curl rc 18 with 301 = failure"   "[ \$(cat $STATE/fail_a) -eq 1 ]"

echo "--- 17. a concurrent run is skipped, not queued ---"
setup 000 28 200 0
: > $STATE/lock
flock -x $STATE/lock -c 'sleep 3' &
LOCKPID=$!
sleep 1
run > /dev/null
assert "locked: probe never ran"         "[ ! -f $EVID/curl_calls ]"
assert "locked: no state written"        "[ ! -f $STATE/fail_a ]"
wait $LOCKPID

echo; echo "RESULTS: $pass passed, $fail failed"
[ $fail -eq 0 ]
