#!/bin/bash
# Is the nightly log copy still arriving? Run from a laptop, not the server: a
# job that never starts can't report itself. Read-only.
#
#   scripts/check_log_ship.sh [prod|test]      (default prod)
#
# Prints the newest object, its age, and the totals. Exits 1 if nothing has
# arrived in the last 36 hours, or if the folder is empty.
set -eu
TARGET="${1:-prod}"
case "$TARGET" in
    prod|test) ;;
    *) echo "usage: $0 [prod|test]" >&2; exit 2 ;;
esac
PROFILE="${AWS_PROFILE:-gluejar_member}"
BUCKET=unglueit-logs
PREFIX="unglue.it/$TARGET/"

LISTING=$(aws --profile "$PROFILE" s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX" \
    --query 'Contents[].[LastModified,Size,Key]' --output text)

printf '%s\n' "$LISTING" | PREFIX="$PREFIX" python3 -c '
import os, sys
from datetime import datetime, timezone

rows = [line.rstrip("\n").split("\t") for line in sys.stdin
        if line.strip() and line.strip() != "None"]
where = "s3://unglueit-logs/" + os.environ["PREFIX"]
if not rows:
    print("NOTHING in " + where)
    sys.exit(1)
newest = max(rows, key=lambda r: r[0])
when = datetime.fromisoformat(newest[0].replace("Z", "+00:00"))
hours = (datetime.now(timezone.utc) - when).total_seconds() / 3600
megabytes = sum(int(r[1]) for r in rows) / 1e6
print(f"{where}: {len(rows)} objects, {megabytes:.0f} MB")
print(f"newest: {newest[2]}")
print(f"        {newest[0]} ({hours:.1f} hours ago)")
if hours > 36:
    print("STALE: nothing new in over 36 hours. Check /var/log/regluit/ship_logs.log on the server.")
    sys.exit(1)
print("OK")
'
