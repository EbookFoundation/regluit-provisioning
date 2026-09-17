#!/bin/bash
# Assertion harness for the crawler rate-limiting jails. Runs inside
# ubuntu:24.04 with the real fail2ban package and the real iptables ban action.
# EbookFoundation/security-private#32.
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq fail2ban iptables nftables >/dev/null 2>&1

pass=0; fail=0
assert() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

cp /work/filter.d/*.conf /etc/fail2ban/filter.d/
cp /work/jail.d/*.conf   /etc/fail2ban/jail.d/
mkdir -p /etc/fail2ban/fail2ban.d /var/log/apache2 /var/run/fail2ban /usr/sbin
printf '[Definition]\nloglevel = NOTICE\n' > /etc/fail2ban/fail2ban.d/regluit-loglevel.conf

# Capture mail instead of sending it.
printf '#!/bin/bash\ncat >> /work/mail\n' > /usr/sbin/sendmail
chmod +x /usr/sbin/sendmail

LOG=/var/log/apache2/ratelimit_access
: > "$LOG"

# The exact shape apache.conf.j2's `ratelimit` LogFormat writes:
#   %h %t "%r" "%{User-Agent}i"
NOW() { date -u +'%d/%b/%Y:%H:%M:%S +0000'; }
line() { # $1=ip $2=request $3=user-agent
  echo "$1 [$(NOW)] \"$2\" \"$3\""
}
burst() { # $1=count $2=ip $3=path-prefix $4=user-agent — one date() for the lot
  local t i; t=$(NOW)
  for ((i=1; i<=$1; i++)); do
    echo "$2 [$t] \"GET $3$i HTTP/1.1\" \"$4\"" >> "$LOG"
  done
}

UA_SCRAPER='CrawlerPlatform-scrapy-crawl/http-evaluation'
UA_GPTBOT='Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.4; +https://openai.com/gptbot)'
UA_GOOGLE='Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'
UA_CHATGPT_USER='Mozilla/5.0 (compatible; ChatGPT-User/1.0; +https://openai.com/bot)'
UA_OAI_SEARCH='Mozilla/5.0 (compatible; OAI-SearchBot/1.0; +https://openai.com/searchbot)'
UA_CLAUDE_SEARCH='Mozilla/5.0 (compatible; Claude-SearchBot/1.0; +searchbot@anthropic.com)'
UA_CLAUDEBOT='Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)'
UA_AMZN_SEARCH='Mozilla/5.0 (compatible; Amzn-SearchBot/1.0)'
UA_META_WEB='meta-webindexer/1.0'
UA_HUMAN='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/145.0.0.0 Safari/537.36'

fbr() { fail2ban-regex "$1" "/etc/fail2ban/filter.d/$2.conf" 2>&1; }
# fail2ban-regex ends with "Lines: N lines, X ignored, M matched, K missed".
hits()   { fbr "$1" "$2" | sed -n 's/^Lines: .*, \([0-9][0-9]*\) matched.*/\1/p'; }
missed() { fbr "$1" "$2" | sed -n 's/^Lines: .*, \([0-9][0-9]*\) missed.*/\1/p'; }

# =====================================================================
echo "=== A. the filters, against the line shape apache really writes ==="
: > /tmp/f.log
line 1.2.3.4 "GET /work/12345 HTTP/1.1"                      "$UA_HUMAN" >> /tmp/f.log
line 1.2.3.5 "GET /search/?q=whitman HTTP/1.1"               "$UA_HUMAN" >> /tmp/f.log
line 1.2.3.6 "GET /socialauth/login/google-oauth2/ HTTP/1.1" "$UA_HUMAN" >> /tmp/f.log
line 1.2.3.7 "POST /feedback/ HTTP/1.1"                      "$UA_HUMAN" >> /tmp/f.log
line 1.2.3.8 "POST /accounts/register/ HTTP/1.1"             "$UA_HUMAN" >> /tmp/f.log

assert "flood matches every ordinary request"  "[ \"\$(hits /tmp/f.log regluit-flood)\" = 5 ]"
assert "flood parses the apache date, missing none" "[ \"\$(missed /tmp/f.log regluit-flood)\" = 0 ]"
assert "expensive matches the four worker-holding paths and nothing else" \
                                               "[ \"\$(hits /tmp/f.log regluit-expensive)\" = 4 ]"

: > /tmp/g.log
line 9.9.9.1 "GET /searching-for-books HTTP/1.1" "$UA_HUMAN" >> /tmp/g.log
line 9.9.9.2 "GET /accounts/login/ HTTP/1.1"     "$UA_HUMAN" >> /tmp/g.log
line 9.9.9.3 "GET /feedbackish HTTP/1.1"         "$UA_HUMAN" >> /tmp/g.log
assert "expensive spares /searching-for-books, /accounts/login/, /feedbackish" \
                                               "[ \"\$(hits /tmp/g.log regluit-expensive)\" = 0 ]"

# =====================================================================
echo "=== B. bad-bot filter: the robots.txt Disallow:/ list, and ONLY it ==="
: > /tmp/b.log
line 5.5.5.1 "GET / HTTP/1.1" "$UA_GPTBOT"                                >> /tmp/b.log
line 5.5.5.2 "GET / HTTP/1.1" "CCBot/2.0 (+https://commoncrawl.org/faq/)" >> /tmp/b.log
line 5.5.5.3 "GET / HTTP/1.1" "Bytespider/1.0"                            >> /tmp/b.log
line 5.5.5.4 "GET / HTTP/1.1" "Amazonbot/0.1"                             >> /tmp/b.log
line 5.5.5.5 "GET / HTTP/1.1" "meta-externalagent/1.1"                    >> /tmp/b.log
line 5.5.5.6 "GET / HTTP/1.1" "Diffbot/0.1"                               >> /tmp/b.log
assert "badbot matches all six agents robots.txt forbids" "[ \"\$(hits /tmp/b.log regluit-badbot)\" = 6 ]"

: > /tmp/ok.log
for ua in "$UA_GOOGLE" "$UA_CHATGPT_USER" "$UA_OAI_SEARCH" "$UA_CLAUDE_SEARCH" "$UA_CLAUDEBOT" \
          "$UA_AMZN_SEARCH" "$UA_META_WEB" "$UA_HUMAN"; do
  line 6.6.6.6 "GET / HTTP/1.1" "$ua" >> /tmp/ok.log
done
assert "badbot spares Googlebot, ChatGPT-User, OAI-SearchBot, Claude-SearchBot, ClaudeBot, Amzn-SearchBot, meta-webindexer, a reader" \
                                               "[ \"\$(hits /tmp/ok.log regluit-badbot)\" = 0 ]"

# A bot name inside the requested URL must not ban the person who asked for it.
: > /tmp/r.log
line 7.7.7.7 "GET /work/about/GPTBot/1.4 HTTP/1.1" "$UA_HUMAN" >> /tmp/r.log
assert "badbot ignores a bot name in the URL, only the user agent counts" \
                                               "[ \"\$(hits /tmp/r.log regluit-badbot)\" = 0 ]"

# =====================================================================
echo "=== C. live: real bans, real firewall rules, real mail ==="
fail2ban-server -xf >/var/log/f2b.out 2>&1 &
sleep 8
assert "fail2ban is up"                        "fail2ban-client ping | grep -q pong"
assert "regluit-flood jail started"            "fail2ban-client status | grep -q regluit-flood"
assert "regluit-expensive jail started"        "fail2ban-client status | grep -q regluit-expensive"
assert "regluit-badbot jail started"           "fail2ban-client status | grep -q regluit-badbot"
assert "Debian's default sshd jail is OFF"     "! fail2ban-client status | grep -q sshd"
assert "the jails read the fixed-path log"     "fail2ban-client get regluit-flood logpath | grep -q '$LOG'"

echo "--- 286 requests: the busiest non-scraper measured on a normal day"
burst 286 10.0.0.9 /work/ "$UA_HUMAN"; sleep 6
assert "286 requests in a minute is NOT banned" "! fail2ban-client status regluit-flood | grep -q 10.0.0.9"

echo "--- 620 requests: over the threshold"
burst 620 10.0.0.2 /work/ "$UA_SCRAPER"; sleep 8
assert "620 requests in a minute IS banned"    "fail2ban-client status regluit-flood | grep -q 10.0.0.2"
assert "the ban is a rule VISIBLE TO iptables -S, not hidden in an nftables table" \
                                               "iptables -S | grep -q 10.0.0.2"
assert "no separate nftables f2b table was created" "! nft list ruleset 2>/dev/null | grep -q f2b-table"
# iptables -S prints the service names resolved to numbers; accept either form,
# and assert 22 is absent so a wrong ban can never cost anyone the box.
assert "the rule covers http and https only, never ssh" \
       "iptables -S | grep -Eq -- '--dports (80,443|http,https)' && ! iptables -S | grep -q -- '--dports .*22'"
assert "the ban mails someone"                 "grep -q '10.0.0.2' /work/mail"
assert "unban removes the firewall rule"       "fail2ban-client unban 10.0.0.2 >/dev/null && sleep 2 && ! iptables -S | grep -q 10.0.0.2"

echo "--- expensive paths: 13/min is the measured human ceiling, 120 is not"
burst 13 10.0.0.3 "/search/?q=" "$UA_HUMAN"; sleep 5
assert "13 searches in a minute is NOT banned" "! fail2ban-client status regluit-expensive | grep -q 10.0.0.3"
burst 120 10.0.0.4 "/socialauth/login/google-oauth2/?n=" "$UA_HUMAN"; sleep 6
assert "120 /socialauth/ hits in a minute IS banned" "fail2ban-client status regluit-expensive | grep -q 10.0.0.4"
assert "and the flood jail did NOT also fire on those 120" \
                                               "! fail2ban-client status regluit-flood | grep -q 10.0.0.4"

echo "--- a declared bad bot, far below every rate threshold"
burst 25 10.0.0.5 /work/ "$UA_GPTBOT"; sleep 6
assert "GPTBot banned at 25 requests"          "fail2ban-client status regluit-badbot | grep -q 10.0.0.5"
burst 25 10.0.0.6 /work/ "$UA_GOOGLE"; sleep 6
assert "Googlebot at the same volume is NOT banned" "! fail2ban-client banned | grep -q 10.0.0.6"

# =====================================================================
echo "=== D. the hourly truncation must not blind the jails ==="
truncate -s 0 "$LOG"; sleep 3
burst 620 10.0.0.7 /work/ "$UA_SCRAPER"; sleep 10
assert "still bans after the log is truncated under it" \
                                               "fail2ban-client status regluit-flood | grep -q 10.0.0.7"

# =====================================================================
echo "=== E. log volume: the flood filter must not copy the access log ==="
FOUND=$(grep -c "Found 10.0.0" /var/log/fail2ban.log 2>/dev/null); FOUND=${FOUND:-0}
assert "per-request 'Found' lines suppressed at NOTICE (got $FOUND)" "[ \"$FOUND\" -eq 0 ]"
assert "Ban lines are still logged"            "grep -q 'Ban 10.0.0.2' /var/log/fail2ban.log"

echo; echo "RESULTS: $pass passed, $fail failed"
[ $fail -eq 0 ]
