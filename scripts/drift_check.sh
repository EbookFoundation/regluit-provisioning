#!/usr/bin/env bash
# drift_check.sh - does a server still match what is merged? Run by hand.
#
# Usage, from the repo root on a machine that can run the playbooks
# (vault password configured, SSH access to the server):
#   scripts/drift_check.sh test
#   scripts/drift_check.sh prod
#
# Three checks, then a one-line verdict:
#   1. App code: the commit deployed on the box vs the tip of the branch it
#      should run (prod: production, test: master) on GitHub.
#   2. Server setup: `setup-<env>.yml --check` (never --diff) and the tasks
#      it reports as "changed". A task the playbook would change is drift:
#      master no longer describes the box.
#   3. Hand edits: scripts/describe_prod.sh on the box, saved under drift/
#      (git-ignored) and compared with the previous run for the same env.
#
# Changes nothing on the server: --check skips the playbooks' raw bootstrap
# steps, and the few tasks marked check_mode: false only read (certificate
# checks, the venv version assertion). The dry run takes about 10 minutes.
# Secrets: --diff is never used, and the tasks that render credentials carry
# no_log. Ansible failure messages can still include task arguments or
# command output, so the full log stays local in drift/ (git-ignored); only
# task names are shown on screen. Treat drift/ as internal.

set -u
set -o pipefail
# Not LC_ALL=C globally: ansible-playbook refuses a non-UTF-8 locale.

case "${1:-}" in
  prod) HOST=unglue.it;      PLAYBOOK=setup-prod.yml; BRANCH=production ;;
  test) HOST=test.unglue.it; PLAYBOOK=setup-test.yml; BRANCH=master ;;
  *) echo "usage: $0 prod|test" >&2; exit 2 ;;
esac
ENV=$1
APP_REPO=https://github.com/Gluejar/regluit.git
cd "$(dirname "$0")/.." || exit 2
mkdir -p drift
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
CHECK_LOG="drift/$ENV-$STAMP-check.log"
DESC="drift/$ENV-$STAMP-describe.txt"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=15 ubuntu@$HOST"

# Tasks that report "changed" on every run by design, so they are not drift.
# Keep the reason next to each name.
ALWAYS_CHANGED=(
  "Start celeryd"                           # service state: reloaded, every run
  "Start celerybeat"                        # service state: restarted, every run
)
# Not ignored, although it may over-report: the pip task (state: present) can
# really move versions to satisfy requirements.txt, so it counts as drift.
PIP_TASK="Install python packages to virtualenv"

if [ -z "${ANSIBLE_VAULT_IDENTITY_LIST:-}${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]; then
  echo "ERROR: no vault password configured (ANSIBLE_VAULT_IDENTITY_LIST or ANSIBLE_VAULT_PASSWORD_FILE)." >&2
  exit 2
fi

echo "drift check: $ENV ($HOST), $(date -u '+%Y-%m-%d %H:%M UTC'), provisioning $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)"
if [ "$(git rev-parse --abbrev-ref HEAD)" != master ] || [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "NOTE: not on a clean master checkout; section 2 compares the box with THIS checkout, not with master."
fi

# --- 1. App code -------------------------------------------------------------
echo
echo "## 1. App code (should run $BRANCH)"
APP_DRIFT=0
DEPLOYED=$($SSH 'git --no-optional-locks -C /opt/regluit rev-parse HEAD' 2>/dev/null)
TIP=$(git ls-remote "$APP_REPO" "refs/heads/$BRANCH" 2>/dev/null | cut -f1)
if [ -z "$DEPLOYED" ] || [ -z "$TIP" ]; then
  echo "ERROR: could not read deployed=${DEPLOYED:-?} tip=${TIP:-?}"
  APP_DRIFT=1
elif [ "$DEPLOYED" = "$TIP" ]; then
  echo "matches: ${DEPLOYED:0:8}"
else
  APP_DRIFT=1
  echo "DIFFERS: deployed ${DEPLOYED:0:8}, $BRANCH tip ${TIP:0:8}"
  if command -v gh >/dev/null; then
    gh api "repos/Gluejar/regluit/compare/$DEPLOYED...$TIP" \
      --jq '"  \(.ahead_by) commit(s) on '"$BRANCH"' not deployed; deployed commit has \(.behind_by) not on '"$BRANCH"'"' 2>/dev/null \
      || echo "  (could not compare; the deployed commit may not be on GitHub)"
  fi
fi

# --- 2. Server setup ---------------------------------------------------------
echo
echo "## 2. Server setup: would $PLAYBOOK --check change anything? (~10 min)"
ansible-playbook -i hosts "$PLAYBOOK" --check > "$CHECK_LOG" 2>&1 < /dev/null
RC=$?
# Attribute each changed:/failed: line to the task or handler header above it.
awk '
  /^TASK \[/            { kind="task";    name=$0; sub(/^TASK \[[^:]*: /,"",name); sub(/^TASK \[/,"",name); sub(/\] \**$/,"",name); next }
  /^RUNNING HANDLER \[/ { kind="handler"; name=$0; sub(/^RUNNING HANDLER \[[^:]*: /,"",name); sub(/\] \**$/,"",name); next }
  /^changed: /          { print kind "\tchanged\t" name }
  /^(fatal|failed): /   { print kind "\tfailed\t" name }
' "$CHECK_LOG" | LC_ALL=C sort -u > "$CHECK_LOG.summary"

is_always() { local t; for t in "${ALWAYS_CHANGED[@]}"; do [ "$t" = "$1" ] && return 0; done; return 1; }
SETUP_DRIFT=0; FAILED=0
REAL=(); ALWAYS=(); HANDLERS=()
while IFS=$'\t' read -r kind what name; do
  if [ "$what" = failed ]; then FAILED=$((FAILED+1)); REAL+=("FAILED: $name"); continue; fi
  if [ "$kind" = handler ]; then HANDLERS+=("$name"); continue; fi
  if is_always "$name"; then ALWAYS+=("$name")
  elif [ "$name" = "$PIP_TASK" ]; then REAL+=("$name (pip may over-report under --check; confirm with a real run on test)")
  else REAL+=("$name"); fi
done < "$CHECK_LOG.summary"
SETUP_DRIFT=${#REAL[@]}
if [ "$SETUP_DRIFT" -eq 0 ]; then
  echo "no task would change"
else
  echo "would change ($SETUP_DRIFT):"
  printf '  - %s\n' "${REAL[@]}"
fi
[ ${#ALWAYS[@]} -gt 0 ] && echo "always reported, ignored: $(IFS=';'; echo "${ALWAYS[*]}" | sed 's/;/; /g')"
[ ${#HANDLERS[@]} -gt 0 ] && echo "handlers that would run as a result: $(IFS=';'; echo "${HANDLERS[*]}" | sed 's/;/; /g')"
grep -E '^PLAY RECAP' -A2 "$CHECK_LOG" | sed -n 2p | sed 's/^/recap: /'
if [ "$RC" -ne 0 ] && [ "$FAILED" -eq 0 ]; then
  echo "ERROR: ansible-playbook exited $RC with no failed task; see $CHECK_LOG"
  SETUP_DRIFT=$((SETUP_DRIFT+1))
fi
echo "full log: $CHECK_LOG"

# --- 3. Hand edits since last run -------------------------------------------
echo
echo "## 3. Files on the box vs the previous run"
# Any failure, ERROR line, or difference counts. A failed or ERROR-containing
# description is renamed *.FAILED.txt so it never becomes the next baseline.
FILE_DRIFT=0
PREV=$(ls -1 drift/"$ENV"-*-describe.txt 2>/dev/null | tail -1)
if ! $SSH "bash -s -- $HOST" < scripts/describe_prod.sh > "$DESC" 2>/dev/null; then
  mv "$DESC" "${DESC%.txt}.FAILED.txt"
  echo "ERROR: describe_prod.sh failed; output in ${DESC%.txt}.FAILED.txt"
  FILE_DRIFT=1
elif grep -q ERROR "$DESC"; then
  mv "$DESC" "${DESC%.txt}.FAILED.txt"
  echo "ERROR: describe_prod.sh reported ERROR lines (kept as ${DESC%.txt}.FAILED.txt, not a baseline):"
  grep ERROR "${DESC%.txt}.FAILED.txt" | sed 's/^/  /'
  FILE_DRIFT=1
elif [ -z "$PREV" ]; then
  echo "first run for $ENV; saved $DESC as the baseline"
elif diff -q "$PREV" "$DESC" >/dev/null; then
  echo "unchanged since $(basename "$PREV")"
else
  FILE_DRIFT=$(diff "$PREV" "$DESC" | grep -c '^[<>]')
  echo "changed since $(basename "$PREV") ($FILE_DRIFT differing line(s)); < before, > now:"
  diff "$PREV" "$DESC" | grep -E '^[<>]' | sed 's/^/  /'
fi

# --- Verdict -----------------------------------------------------------------
echo
if [ "$APP_DRIFT" -eq 0 ] && [ "$SETUP_DRIFT" -eq 0 ] && [ "$FILE_DRIFT" -eq 0 ]; then
  echo "VERDICT $ENV: NO DRIFT"
else
  echo "VERDICT $ENV: DRIFT: $APP_DRIFT app / $SETUP_DRIFT setup / $FILE_DRIFT files"
fi
