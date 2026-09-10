#!/bin/bash
# Test harness for wsgi_wedge_watch.sh — runs inside ubuntu container.
# Mocks: ps, logger (PATH shims), kill (exported function — PATH can't shadow a
# bash builtin) + /usr/sbin/sendmail. Real: grep/sed/date/cat.
set -u
cd /work
FIXDATE=$(date +"%a %b %d")           # today
YDATE=$(date -d yesterday +"%a %b %d")
YEAR=$(date +%Y)
mkdir -p mockbin evidence
export EVID=/work/evidence

# ---- fixture error logs ----
LOGDIR=/var/log/apache2; mkdir -p $LOGDIR
LOG="$LOGDIR/$(date +%Y%m%d)_error.log"
YLOG="$LOGDIR/$(date -d yesterday +%Y%m%d)_error.log"

emit_failure() { # $1=file $2=datestr $3=time $4=pid
cat >> "$1" <<EOF
[$2 $3.208555 $YEAR] [wsgi:error] [pid $4:tid 1241] mod_wsgi (pid=$4): Failed to exec Python script file '/opt/regluit/deploy/prod.wsgi'.
[$2 $3.208632 $YEAR] [wsgi:error] [pid $4:tid 1241] mod_wsgi (pid=$4): Exception occurred processing WSGI script '/opt/regluit/deploy/prod.wsgi'.
[$2 $3.218438 $YEAR] [wsgi:error] [pid $4:tid 1241] Traceback (most recent call last):
[$2 $3.219840 $YEAR] [wsgi:error] [pid $4:tid 1241] ValueError: not enough values to unpack (expected 2, got 1)
EOF
}

# pid 501: wedged today (old process, failures today)          -> KILL
# pid 502: failures today but process dead                     -> skip
# pid 503: failures today, young process (pid reuse)           -> skip
# pid 505: failure timestamp == process start second (tie)     -> skip (fail-safe)
# pid 506: wedged, failures ONLY in yesterday's log (midnight) -> KILL
emit_failure "$LOG"  "$FIXDATE" "01:15:08" 501
emit_failure "$LOG"  "$FIXDATE" "01:15:08" 502
emit_failure "$LOG"  "$FIXDATE" "01:15:08" 503
TIE_TIME=$(date +%H:%M:%S); TIE_EPOCH=$(date +%s)
emit_failure "$LOG"  "$FIXDATE" "$TIE_TIME" 505
emit_failure "$YLOG" "$YDATE"   "23:59:01" 506
echo "[$FIXDATE 01:15:09.000000 $YEAR] [mpm_event:notice] [pid 504:tid 1] AH00489: resuming normal operations" >> "$LOG"

# ---- mocks ----
cat > mockbin/ps <<EOF
#!/bin/bash
PID=\$2; FMT=\$4
NOW=\$(date +%s)
case "\$PID" in
  501) [ "\$FMT" = "cmd=" ] && echo "(wsgi:regluit)  -k start" || echo "  90000" ;;
  502) exit 1 ;;
  503) [ "\$FMT" = "cmd=" ] && echo "(wsgi:regluit)  -k start" || echo "  10" ;;
  505) [ "\$FMT" = "cmd=" ] && echo "(wsgi:regluit)  -k start" || echo \$(( NOW - $TIE_EPOCH )) ;;
  506) [ "\$FMT" = "cmd=" ] && echo "(wsgi:regluit)  -k start" || echo "  90000" ;;
  *) exit 1 ;;
esac
EOF
cat > mockbin/logger <<'EOF'
#!/bin/bash
echo "LOGGER $*" >> "$EVID/logger"
EOF
chmod +x mockbin/*
kill() { echo "KILL $*" >> "$EVID/kills"; }
export -f kill
mkdir -p /usr/sbin
cat > /usr/sbin/sendmail <<'EOF'
#!/bin/bash
cat >> "$EVID/mail"
EOF
chmod +x /usr/sbin/sendmail

# ---- run ----
PATH=/work/mockbin:$PATH bash /work/watch.sh
RC=$?

# ---- assertions ----
pass=0; fail=0
assert() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
assert "exit code 0"                       "[ $RC -eq 0 ]"
assert "wedged pid 501 killed"             "grep -q 'KILL 501' $EVID/kills"
assert "midnight-edge pid 506 killed"      "grep -q 'KILL 506' $EVID/kills"
assert "exactly two kills"                 "[ \$(wc -l < $EVID/kills) -eq 2 ]"
assert "dead pid 502 not killed"           "! grep -q 502 $EVID/kills"
assert "reused pid 503 not killed"         "! grep -q 503 $EVID/kills"
assert "same-second tie 505 not killed"    "! grep -q 505 $EVID/kills"
assert "alert mail sent"                   "grep -q 'wedged wsgi worker auto-healed' $EVID/mail"
assert "mail includes pid 501"             "grep -q 'pid: 501' $EVID/mail"
assert "mail includes pid 506"             "grep -q 'pid: 506' $EVID/mail"
assert "mail includes traceback"           "grep -q 'ValueError: not enough values' $EVID/mail"
assert "syslog line written"               "grep -q 'killing wedged wsgi daemon pid=501' $EVID/logger"

# ---- no-failure logs: quiet no-op ----
: > "$EVID/kills"
echo "[$FIXDATE 01:00:00.000000 $YEAR] [mpm_event:notice] [pid 1:tid 1] AH00489: resuming" > "$LOG"
rm -f "$YLOG"
PATH=/work/mockbin:$PATH bash /work/watch.sh; RC2=$?
assert "clean log: exit 0"                 "[ $RC2 -eq 0 ]"
assert "clean log: no kills"               "[ ! -s $EVID/kills ]"

# ---- missing log files entirely ----
rm -f "$LOG"
PATH=/work/mockbin:$PATH bash /work/watch.sh; RC3=$?
assert "missing logs: exit 0"              "[ $RC3 -eq 0 ]"

echo; echo "RESULTS: $pass passed, $fail failed"
[ $fail -eq 0 ]
