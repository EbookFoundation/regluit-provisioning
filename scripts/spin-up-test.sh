#!/usr/bin/env bash
set -euo pipefail

# Spin up test.unglue.it from stopped state.
# Starts EC2, restores RDS from most recent teardown snapshot, runs Ansible.
#
# Usage: ./scripts/spin-up-test.sh [git-branch]
# Example: ./scripts/spin-up-test.sh bot-protection-downloads

source "$(dirname "$0")/test-env.conf"

GIT_BRANCH="${1:-production}"

echo "=== Spinning up test.unglue.it ==="
echo "    Git branch: ${GIT_BRANCH}"
echo ""

# --- EC2 ---
echo "1/5  Starting EC2 instance ${INSTANCE_ID}..."
EC2_STATE=$(_aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)

if [ "$EC2_STATE" = "stopped" ]; then
    _aws ec2 start-instances --instance-ids "$INSTANCE_ID" > /dev/null
    echo "     Start initiated. Waiting for running state..."
    _aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
    echo "     Running."
elif [ "$EC2_STATE" = "running" ]; then
    echo "     Already running."
else
    echo "     State: ${EC2_STATE} — cannot start. Exiting."
    exit 1
fi

# Get public IP (may have changed)
PUBLIC_IP=$(_aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
echo "     Public IP: ${PUBLIC_IP}"

# --- Update hosts file if IP changed ---
CURRENT_IP=$(grep 'regluit-test' "${PROVISIONING_DIR}/hosts" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo "")
if [ "$CURRENT_IP" != "$PUBLIC_IP" ]; then
    echo ""
    echo "2/5  Updating hosts file (${CURRENT_IP} → ${PUBLIC_IP})..."
    sed -i '' "s/ansible_host=${CURRENT_IP}/ansible_host=${PUBLIC_IP}/" "${PROVISIONING_DIR}/hosts"
    echo "     Updated."

    # Update Route 53 if IP changed
    echo "     Updating DNS (test.unglue.it → ${PUBLIC_IP})..."
    HOSTED_ZONE_ID=$(_aws route53 list-hosted-zones-by-name \
        --dns-name "unglue.it" \
        --query 'HostedZones[0].Id' \
        --output text | sed 's|/hostedzone/||')
    _aws route53 change-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --change-batch "{
            \"Changes\": [{
                \"Action\": \"UPSERT\",
                \"ResourceRecordSet\": {
                    \"Name\": \"test.unglue.it\",
                    \"Type\": \"A\",
                    \"TTL\": 300,
                    \"ResourceRecords\": [{\"Value\": \"${PUBLIC_IP}\"}]
                }
            }]
        }" > /dev/null
    echo "     DNS updated."
else
    echo ""
    echo "2/5  IP unchanged (${PUBLIC_IP}), skipping hosts/DNS update."
fi

# --- RDS ---
echo ""
echo "3/5  Checking RDS instance ${RDS_INSTANCE}..."
RDS_STATE=$(_aws rds describe-db-instances \
    --db-instance-identifier "$RDS_INSTANCE" \
    --query 'DBInstances[0].DBInstanceStatus' \
    --output text 2>/dev/null || echo "not-found")

if [ "$RDS_STATE" = "not-found" ]; then
    # Find most recent teardown snapshot
    LATEST_SNAPSHOT=$(_aws rds describe-db-snapshots \
        --query "reverse(sort_by(DBSnapshots[?starts_with(DBSnapshotIdentifier, '${SNAPSHOT_PREFIX}')], &SnapshotCreateTime))[0].DBSnapshotIdentifier" \
        --output text)

    if [ "$LATEST_SNAPSHOT" = "None" ] || [ -z "$LATEST_SNAPSHOT" ]; then
        # Fall back to most recent automated production snapshot
        LATEST_SNAPSHOT=$(_aws rds describe-db-snapshots \
            --db-instance-identifier "production-2024" \
            --snapshot-type automated \
            --query 'reverse(sort_by(DBSnapshots, &SnapshotCreateTime))[0].DBSnapshotIdentifier' \
            --output text)
        echo "     No teardown snapshot found. Using production snapshot: ${LATEST_SNAPSHOT}"
    else
        echo "     Restoring from teardown snapshot: ${LATEST_SNAPSHOT}"
    fi

    _aws rds restore-db-instance-from-db-snapshot \
        --db-instance-identifier "$RDS_INSTANCE" \
        --db-snapshot-identifier "$LATEST_SNAPSHOT" \
        --db-instance-class db.t3.medium \
        --db-subnet-group-name "$RDS_SUBNET_GROUP" \
        --vpc-security-group-ids "$RDS_SECURITY_GROUP" \
        --no-multi-az > /dev/null

    echo "     Restore initiated. Waiting for RDS to become available... (5-10 min)"
    _aws rds wait db-instance-available \
        --db-instance-identifier "$RDS_INSTANCE"
    echo "     RDS available."
elif [ "$RDS_STATE" = "available" ]; then
    echo "     Already available."
elif [ "$RDS_STATE" = "stopped" ]; then
    echo "     Starting stopped RDS instance..."
    _aws rds start-db-instance \
        --db-instance-identifier "$RDS_INSTANCE" > /dev/null
    echo "     Waiting for RDS to become available..."
    _aws rds wait db-instance-available \
        --db-instance-identifier "$RDS_INSTANCE"
    echo "     RDS available."
else
    echo "     State: ${RDS_STATE} — waiting for it to become available..."
    _aws rds wait db-instance-available \
        --db-instance-identifier "$RDS_INSTANCE"
    echo "     RDS available."
fi

# Get RDS endpoint
RDS_ENDPOINT=$(_aws rds describe-db-instances \
    --db-instance-identifier "$RDS_INSTANCE" \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text)
echo "     RDS endpoint: ${RDS_ENDPOINT}"

# --- Wait for SSH ---
echo ""
echo "4/5  Waiting for SSH access..."
for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        -i "$SSH_KEY" "ubuntu@${PUBLIC_IP}" 'echo ok' 2>/dev/null; then
        echo "     SSH ready."
        break
    fi
    if [ "$i" = "30" ]; then
        echo "     SSH timeout after 30 attempts. Continuing with Ansible anyway..."
    fi
    sleep 2
done

# --- Ansible ---
echo ""
echo "5/5  Running Ansible deploy..."
cd "$PROVISIONING_DIR"
ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PASS" ansible-playbook \
    -i hosts setup-test.yml \
    -e "git_branch=${GIT_BRANCH}"

echo ""
echo "=== test.unglue.it is ready ==="
echo ""
echo "  URL:  https://test.unglue.it/"
echo "  SSH:  ssh -i ${SSH_KEY} ubuntu@${PUBLIC_IP}"
echo "  Branch: ${GIT_BRANCH}"
echo ""
echo "  When done: ./scripts/tear-down-test.sh"
