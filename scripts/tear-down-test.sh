#!/usr/bin/env bash
set -euo pipefail

# Tear down test.unglue.it to minimize costs.
# Stops EC2, snapshots + deletes RDS.
# Idle cost: ~$0.12/day (EBS storage + Elastic IP only)
#
# Usage: ./scripts/tear-down-test.sh

source "$(dirname "$0")/test-env.conf"

echo "=== Tearing down test.unglue.it ==="
echo ""

# --- EC2 ---
echo "1/4  Checking EC2 instance ${INSTANCE_ID}..."
EC2_STATE=$(_aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "not-found")

if [ "$EC2_STATE" = "running" ]; then
    echo "     Stopping EC2 instance..."
    _aws ec2 stop-instances --instance-ids "$INSTANCE_ID" > /dev/null
    echo "     Stop initiated. (Will complete in ~30s)"
elif [ "$EC2_STATE" = "stopped" ]; then
    echo "     Already stopped."
else
    echo "     State: ${EC2_STATE} — skipping."
fi

# --- RDS ---
echo ""
echo "2/4  Checking RDS instance ${RDS_INSTANCE}..."
RDS_STATE=$(_aws rds describe-db-instances \
    --db-instance-identifier "$RDS_INSTANCE" \
    --query 'DBInstances[0].DBInstanceStatus' \
    --output text 2>/dev/null || echo "not-found")

if [ "$RDS_STATE" = "not-found" ]; then
    echo "     RDS instance not found — already deleted or never created."
    echo ""
    echo "=== Done. EC2 stopping, no RDS to clean up. ==="
    exit 0
fi

echo "     RDS state: ${RDS_STATE}"

SNAPSHOT_ID="${SNAPSHOT_PREFIX}-$(date +%Y%m%d-%H%M)"
echo ""
echo "3/4  Creating RDS snapshot: ${SNAPSHOT_ID}..."
_aws rds create-db-snapshot \
    --db-instance-identifier "$RDS_INSTANCE" \
    --db-snapshot-identifier "$SNAPSHOT_ID" > /dev/null

echo "     Waiting for snapshot to complete... (this takes a few minutes)"
_aws rds wait db-snapshot-available \
    --db-snapshot-identifier "$SNAPSHOT_ID"
echo "     Snapshot ready."

echo ""
echo "4/4  Deleting RDS instance ${RDS_INSTANCE} (snapshot saved as ${SNAPSHOT_ID})..."
_aws rds delete-db-instance \
    --db-instance-identifier "$RDS_INSTANCE" \
    --skip-final-snapshot > /dev/null
echo "     Delete initiated."

echo ""
echo "=== Teardown complete ==="
echo ""
echo "Idle costs: ~\$0.12/day (EBS + Elastic IP)"
echo "Snapshot:   ${SNAPSHOT_ID}"
echo ""
echo "To restore: ./scripts/spin-up-test.sh"
