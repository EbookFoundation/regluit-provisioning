#!/usr/bin/env bash
set -euo pipefail

# Check the current state and cost of test.unglue.it infrastructure.
#
# Usage: ./scripts/test-status.sh

source "$(dirname "$0")/test-env.conf"

echo "=== test.unglue.it status ==="
echo ""

# --- EC2 ---
EC2_STATE=$(_aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "not-found")

PUBLIC_IP=$(_aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text 2>/dev/null || echo "n/a")

echo "EC2:  ${EC2_STATE}  (${INSTANCE_ID})"
if [ "$PUBLIC_IP" != "None" ] && [ "$PUBLIC_IP" != "n/a" ]; then
    echo "      IP: ${PUBLIC_IP}"
fi

# --- RDS ---
RDS_STATE=$(_aws rds describe-db-instances \
    --db-instance-identifier "$RDS_INSTANCE" \
    --query 'DBInstances[0].DBInstanceStatus' \
    --output text 2>/dev/null || echo "not-found")

echo "RDS:  ${RDS_STATE}  (${RDS_INSTANCE})"

# --- Snapshots ---
SNAPSHOT_COUNT=$(_aws rds describe-db-snapshots \
    --query "length(DBSnapshots[?starts_with(DBSnapshotIdentifier, '${SNAPSHOT_PREFIX}')])" \
    --output text 2>/dev/null || echo "0")

LATEST_SNAPSHOT=$(_aws rds describe-db-snapshots \
    --query "reverse(sort_by(DBSnapshots[?starts_with(DBSnapshotIdentifier, '${SNAPSHOT_PREFIX}')], &SnapshotCreateTime))[0].[DBSnapshotIdentifier, SnapshotCreateTime]" \
    --output text 2>/dev/null || echo "none")

echo "Snapshots: ${SNAPSHOT_COUNT} teardown snapshot(s)"
if [ "$LATEST_SNAPSHOT" != "none" ] && [ "$LATEST_SNAPSHOT" != "None" ]; then
    echo "      Latest: ${LATEST_SNAPSHOT}"
fi

# --- Cost estimate ---
echo ""
DAILY_COST="0.00"
if [ "$EC2_STATE" = "running" ]; then
    DAILY_COST=$(echo "$DAILY_COST + 1.01" | bc)
    echo "Cost: EC2 running        \$1.01/day"
elif [ "$EC2_STATE" = "stopped" ]; then
    DAILY_COST=$(echo "$DAILY_COST + 0.22" | bc)
    echo "Cost: EC2 stopped        \$0.22/day (EBS + Elastic IP)"
fi

if [ "$RDS_STATE" = "available" ] || [ "$RDS_STATE" = "stopped" ]; then
    DAILY_COST=$(echo "$DAILY_COST + 1.70" | bc)
    echo "Cost: RDS (exists)       \$1.70/day"
elif [ "$RDS_STATE" = "not-found" ]; then
    DAILY_COST=$(echo "$DAILY_COST + 0.02" | bc)
    echo "Cost: RDS (snapshot only) \$0.02/day"
fi

echo "      ─────────────────────"
echo "      Total:              ~\$${DAILY_COST}/day"

echo ""
if [ "$EC2_STATE" = "running" ] && [ "$RDS_STATE" = "available" ]; then
    echo "Action: Ready to use. Run ./scripts/tear-down-test.sh when done."
elif [ "$EC2_STATE" = "stopped" ] && [ "$RDS_STATE" = "not-found" ]; then
    echo "Action: Low-cost mode. Run ./scripts/spin-up-test.sh to resume."
else
    echo "Action: Mixed state. Check components above."
fi
