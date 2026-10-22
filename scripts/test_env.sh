#!/bin/bash
# test_env.sh — run test.unglue.it on demand: off unless someone turns it on,
# and AWS stops it every night.
#
#   scripts/test_env.sh status            one line for the server, one for the database
#   scripts/test_env.sh up                start both, wait until https://test.unglue.it/ answers (5-10 min)
#   scripts/test_env.sh down              stop both (safe to run twice)
#   scripts/test_env.sh install-schedule  create the nightly 02:00 PT stop (one-time; re-run after a rebuild)
#   scripts/test_env.sh remove-schedule   delete the nightly stop and its IAM role
#
# Why the nightly stop: AWS restarts a stopped RDS database by itself after 7
# days, and people forget to stop things. The schedules are EventBridge
# Scheduler calling RDS StopDBInstance and EC2 StopInstances directly: no Lambda,
# nothing running on anyone's laptop. A stop that finds test already stopped
# just fails quietly (no retries).
#
# While stopped, test costs its server disk, its Elastic IP (kept, so
# test.unglue.it keeps its address) and its database storage: about $35/month
# against about $135 running.
#
# Overrides (test gets rebuilt with new names): TEST_INSTANCE_NAME, TEST_DB_ID,
# TEST_URL, AWS_PROFILE_NAME, TEST_ACCOUNT_ID. Anything whose name looks like
# production is refused, and so is any account other than TEST_ACCOUNT_ID
# (default: the Gluejar member account, 439256357102).
set -euo pipefail

PROFILE="${AWS_PROFILE_NAME:-gluejar_member}"
REGION=us-east-1
INSTANCE_NAME="${TEST_INSTANCE_NAME:-test-2026-06-18}"
DB_ID="${TEST_DB_ID:-test-2026-08-23}"
URL="${TEST_URL:-https://test.unglue.it/}"
ROLE=unglueit-test-nightly-stop
SCHED_DB=unglueit-test-stop-db
SCHED_EC2=unglueit-test-stop-server
AWS=(aws --profile "$PROFILE" --region "$REGION")

die() { echo "test_env: $*" >&2; exit 1; }

for name in "$INSTANCE_NAME" "$DB_ID"; do
  # case-insensitive; tr, not ${name,,}, because macOS /bin/bash is 3.2
  case "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" in
    *prod*|*green*|*blue*) die "refusing: '$name' looks like a production resource" ;;
  esac
done

# Only ever act in the account test lives in (Gluejar member account), so a
# profile pointing somewhere else can't create schedules or roles there.
EXPECTED_ACCOUNT="${TEST_ACCOUNT_ID:-439256357102}"
ACCOUNT=$("${AWS[@]}" sts get-caller-identity --query Account --output text) || die "AWS profile '$PROFILE' did not authenticate"
[ "$ACCOUNT" = "$EXPECTED_ACCOUNT" ] || die "refusing: profile '$PROFILE' is account $ACCOUNT, expected $EXPECTED_ACCOUNT (set TEST_ACCOUNT_ID to override)"

instance_id() {
  local ids
  ids=$("${AWS[@]}" ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [ -n "$ids" ] || die "no instance named $INSTANCE_NAME"
  [ "$(wc -w <<<"$ids")" -eq 1 ] || die "more than one instance named $INSTANCE_NAME: $ids"
  echo "$ids"
}
instance_state() { "${AWS[@]}" ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].State.Name' --output text; }
db_state() { "${AWS[@]}" rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].DBInstanceStatus' --output text; }
db_arn() { "${AWS[@]}" rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].DBInstanceArn' --output text; }

cmd_status() {
  local iid; iid=$(instance_id)
  echo "server   $INSTANCE_NAME ($iid): $(instance_state "$iid")"
  echo "database $DB_ID: $(db_state)"
  # counters and a string, not arrays: empty arrays under set -u are unsafe in bash 3.2
  local found=0 missing=""
  for s in "$SCHED_DB" "$SCHED_EC2"; do
    if "${AWS[@]}" scheduler get-schedule --name "$s" >/dev/null 2>&1; then found=$((found + 1)); else missing="$missing $s"; fi
  done
  if [ "$found" -eq 2 ]; then
    echo "nightly stop: installed (02:00 America/Los_Angeles)"
  elif [ "$found" -eq 0 ]; then
    echo "nightly stop: not installed (run: $0 install-schedule)"
  else
    echo "nightly stop: PARTIAL, missing$missing (re-run: $0 install-schedule)"
  fi
}

cmd_up() {
  local iid; iid=$(instance_id)
  if [ "$(db_state)" = stopping ]; then
    echo "database is still stopping (e.g. right after 'down'); waiting for that to finish..."
    for _ in $(seq 1 90); do [ "$(db_state)" = stopped ] && break; sleep 10; done
  fi
  case "$(db_state)" in
    stopped) echo "starting database $DB_ID"; "${AWS[@]}" rds start-db-instance --db-instance-identifier "$DB_ID" >/dev/null ;;
    available|starting) ;;
    *) echo "database is $(db_state); waiting for it" ;;
  esac
  case "$(instance_state "$iid")" in
    stopped) echo "starting server $iid"; "${AWS[@]}" ec2 start-instances --instance-ids "$iid" >/dev/null ;;
    stopping) echo "server is stopping; waiting, then starting"; "${AWS[@]}" ec2 wait instance-stopped --instance-ids "$iid"
              "${AWS[@]}" ec2 start-instances --instance-ids "$iid" >/dev/null ;;
  esac
  echo "waiting for the database (often the slow part, 5-10 min)..."
  "${AWS[@]}" rds wait db-instance-available --db-instance-identifier "$DB_ID"
  echo "waiting for the server..."
  "${AWS[@]}" ec2 wait instance-running --instance-ids "$iid"
  echo "waiting for $URL to answer..."
  for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$URL" || true)
    if [ "$code" = 200 ]; then echo "test is up: $URL answered 200"; return 0; fi
    sleep 10
  done
  die "server and database are up, but $URL did not answer 200 within 10 minutes (last: $code). Check Apache on the box."
}

cmd_down() {
  local iid; iid=$(instance_id)
  case "$(instance_state "$iid")" in
    running|pending) echo "stopping server $iid"; "${AWS[@]}" ec2 stop-instances --instance-ids "$iid" >/dev/null ;;
    *) echo "server already $(instance_state "$iid")" ;;
  esac
  case "$(db_state)" in
    available) echo "stopping database $DB_ID"; "${AWS[@]}" rds stop-db-instance --db-instance-identifier "$DB_ID" >/dev/null ;;
    *) echo "database is $(db_state); not stopping it now (run down again once it is available)" ;;
  esac
  echo "stop requested. '$0 status' shows progress."
}

cmd_install_schedule() {
  local iid account role_arn
  iid=$(instance_id)
  account="$ACCOUNT"
  local tmp; tmp=$(mktemp -d)
  cat > "$tmp/trust.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:SourceAccount":"$account"}}}]}
EOF
  cat > "$tmp/policy.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"rds:StopDBInstance","Resource":"$(db_arn)"},
 {"Effect":"Allow","Action":"ec2:StopInstances","Resource":"arn:aws:ec2:$REGION:$account:instance/$iid"}]}
EOF
  if ! "${AWS[@]}" iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    "${AWS[@]}" iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$tmp/trust.json" \
      --description "EventBridge Scheduler: nightly stop of test.unglue.it (scripts/test_env.sh)" >/dev/null
    echo "created role $ROLE; waiting for IAM to settle"; sleep 10
  else
    # Reusing an existing role: it must carry nothing but our own inline policy,
    # and its trust is reset to ours, so the schedules can't inherit wider powers.
    local attached others
    attached=$("${AWS[@]}" iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text)
    others=$("${AWS[@]}" iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[?@!=`stop-test`]' --output text)
    [ -z "$attached" ] && [ -z "$others" ] || die "refusing: role $ROLE has other policies ($attached $others); inspect it or run remove-schedule first"
    "${AWS[@]}" iam update-assume-role-policy --role-name "$ROLE" --policy-document "file://$tmp/trust.json"
  fi
  # put-role-policy replaces the policy, so a rebuilt test (new ids) just re-runs this.
  "${AWS[@]}" iam put-role-policy --role-name "$ROLE" --policy-name stop-test --policy-document "file://$tmp/policy.json"
  role_arn=$("${AWS[@]}" iam get-role --role-name "$ROLE" --query Role.Arn --output text)
  for s in "$SCHED_DB" "$SCHED_EC2"; do "${AWS[@]}" scheduler delete-schedule --name "$s" >/dev/null 2>&1 || true; done
  "${AWS[@]}" scheduler create-schedule --name "$SCHED_DB" \
    --schedule-expression 'cron(0 2 * * ? *)' --schedule-expression-timezone America/Los_Angeles \
    --flexible-time-window Mode=OFF \
    --target "{\"Arn\":\"arn:aws:scheduler:::aws-sdk:rds:stopDBInstance\",\"RoleArn\":\"$role_arn\",\"Input\":\"{\\\"DbInstanceIdentifier\\\":\\\"$DB_ID\\\"}\",\"RetryPolicy\":{\"MaximumRetryAttempts\":0}}" >/dev/null
  "${AWS[@]}" scheduler create-schedule --name "$SCHED_EC2" \
    --schedule-expression 'cron(0 2 * * ? *)' --schedule-expression-timezone America/Los_Angeles \
    --flexible-time-window Mode=OFF \
    --target "{\"Arn\":\"arn:aws:scheduler:::aws-sdk:ec2:stopInstances\",\"RoleArn\":\"$role_arn\",\"Input\":\"{\\\"InstanceIds\\\":[\\\"$iid\\\"]}\",\"RetryPolicy\":{\"MaximumRetryAttempts\":0}}" >/dev/null
  rm -rf "$tmp"
  echo "nightly stop installed: $SCHED_DB ($DB_ID) and $SCHED_EC2 ($iid), 02:00 America/Los_Angeles"
}

cmd_remove_schedule() {
  for s in "$SCHED_DB" "$SCHED_EC2"; do
    "${AWS[@]}" scheduler delete-schedule --name "$s" 2>/dev/null && echo "deleted schedule $s" || echo "no schedule $s"
  done
  "${AWS[@]}" iam delete-role-policy --role-name "$ROLE" --policy-name stop-test 2>/dev/null || true
  "${AWS[@]}" iam delete-role --role-name "$ROLE" 2>/dev/null && echo "deleted role $ROLE" || echo "no role $ROLE"
}

case "${1:-}" in
  status) cmd_status ;;
  up) cmd_up ;;
  down) cmd_down ;;
  install-schedule) cmd_install_schedule ;;
  remove-schedule) cmd_remove_schedule ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
