#!/bin/bash
#
# tear-down-test.sh - Terminate an ephemeral EC2 test environment
#
# This script terminates the EC2 instance created by spin-up-test.sh
# and cleans up associated resources.
#
# Usage: ./tear-down-test.sh [--force]
#
# Options:
#   --force    Skip confirmation prompt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONING_DIR="$(dirname "$SCRIPT_DIR")"
METADATA_FILE="$PROVISIONING_DIR/.test-instance"

FORCE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--force]"
            echo ""
            echo "Options:"
            echo "  --force, -f    Skip confirmation prompt"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=== Regluit Test Environment Tear Down ==="
echo ""

# Check for metadata file
if [[ ! -f "$METADATA_FILE" ]]; then
    echo "Error: No test instance metadata found."
    echo "The file $METADATA_FILE does not exist."
    echo ""
    echo "If you know the instance ID, you can terminate it manually:"
    echo "  aws ec2 terminate-instances --instance-ids <instance-id>"
    exit 1
fi

# Load metadata
source "$METADATA_FILE"

echo "Instance found:"
echo "  ID: $INSTANCE_ID"
echo "  Name: $INSTANCE_NAME"
echo "  IP: $PUBLIC_IP"
echo "  Region: $REGION"
echo "  Created: $CREATED_AT"
echo ""

# Check if instance still exists
INSTANCE_STATE=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "not-found")

if [[ "$INSTANCE_STATE" == "not-found" || "$INSTANCE_STATE" == "terminated" ]]; then
    echo "Instance is already terminated or not found."
    rm -f "$METADATA_FILE"
    exit 0
fi

echo "Current state: $INSTANCE_STATE"
echo ""

# Confirm termination
if ! $FORCE; then
    read -p "Are you sure you want to terminate this instance? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Terminate instance
echo "Terminating instance..."
aws ec2 terminate-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --output text

echo "Waiting for termination to complete..."
aws ec2 wait instance-terminated \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" 2>/dev/null || true

# Clean up metadata file
rm -f "$METADATA_FILE"

# Update hosts file - comment out the test entry
HOSTS_FILE="$PROVISIONING_DIR/hosts"
if grep -q "^\[test\]" "$HOSTS_FILE"; then
    # Comment out the test host entry
    sed -i.bak '/^\[test\]/,/^\[/{s/^regluit-test /#regluit-test /}' "$HOSTS_FILE"
fi

echo ""
echo "=== Test Environment Terminated ==="
echo ""
echo "Instance $INSTANCE_ID has been terminated."
echo "The hosts file has been updated (test entry commented out)."
