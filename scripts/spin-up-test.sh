#!/bin/bash
#
# spin-up-test.sh - Provision an ephemeral EC2 test environment
#
# This script creates a t3.medium EC2 instance for testing Django upgrades,
# Ansible validation, and feature development with production-like data.
#
# Usage: ./spin-up-test.sh [--with-rds]
#
# Options:
#   --with-rds    Clone production RDS instead of using local MySQL
#
# Estimated cost: $0.35-0.65/day for EC2-only, more with RDS cloning
#
# Prerequisites:
#   - AWS CLI configured with appropriate credentials
#   - SSH key pair named 'regluit-test' in AWS
#   - Ansible installed locally
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONING_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
AMI_ID="${AMI_ID:-}"  # Will be auto-detected if not set
KEY_NAME="${KEY_NAME:-regluit-test}"
SECURITY_GROUP="${SECURITY_GROUP:-regluit-test-sg}"
REGION="${AWS_REGION:-us-east-1}"
INSTANCE_NAME="regluit-test-$(date +%Y%m%d-%H%M%S)"
WITH_RDS=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --with-rds)
            WITH_RDS=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--with-rds]"
            echo ""
            echo "Options:"
            echo "  --with-rds    Clone production RDS instead of using local MySQL"
            echo ""
            echo "Environment variables:"
            echo "  INSTANCE_TYPE    EC2 instance type (default: t3.medium)"
            echo "  AMI_ID           AMI ID (default: auto-detect latest Ubuntu 22.04)"
            echo "  KEY_NAME         SSH key pair name (default: regluit-test)"
            echo "  SECURITY_GROUP   Security group name (default: regluit-test-sg)"
            echo "  AWS_REGION       AWS region (default: us-east-1)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=== Regluit Ephemeral Test Environment Setup ==="
echo "Instance type: $INSTANCE_TYPE"
echo "Region: $REGION"
echo "With RDS: $WITH_RDS"
echo ""

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI not found. Please install it first."
    exit 1
fi

# Verify AWS credentials
echo "Verifying AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    echo "Error: AWS credentials not configured or invalid."
    exit 1
fi

# Auto-detect AMI if not specified (Ubuntu 22.04 LTS)
if [[ -z "$AMI_ID" ]]; then
    echo "Auto-detecting latest Ubuntu 22.04 LTS AMI..."
    AMI_ID=$(aws ec2 describe-images \
        --region "$REGION" \
        --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
                  "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)

    if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
        echo "Error: Could not find Ubuntu 22.04 AMI"
        exit 1
    fi
    echo "Using AMI: $AMI_ID"
fi

# Check/create security group
echo "Checking security group..."
SG_ID=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=group-name,Values=$SECURITY_GROUP" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
    echo "Creating security group: $SECURITY_GROUP"
    SG_ID=$(aws ec2 create-security-group \
        --region "$REGION" \
        --group-name "$SECURITY_GROUP" \
        --description "Security group for regluit test environments" \
        --query 'GroupId' \
        --output text)

    # Add SSH access
    aws ec2 authorize-security-group-ingress \
        --region "$REGION" \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0

    # Add HTTP access
    aws ec2 authorize-security-group-ingress \
        --region "$REGION" \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0

    # Add HTTPS access
    aws ec2 authorize-security-group-ingress \
        --region "$REGION" \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0

    echo "Security group created: $SG_ID"
else
    echo "Using existing security group: $SG_ID"
fi

# Check if key pair exists
echo "Checking SSH key pair..."
if ! aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" &> /dev/null; then
    echo "Error: SSH key pair '$KEY_NAME' not found in AWS."
    echo "Create it with: aws ec2 create-key-pair --key-name $KEY_NAME --query 'KeyMaterial' --output text > ~/.ssh/$KEY_NAME.pem"
    exit 1
fi

# Launch EC2 instance
echo "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Environment,Value=test},{Key=Project,Value=regluit}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance launched: $INSTANCE_ID"
echo "Waiting for instance to be running..."

aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo "Instance is running at: $PUBLIC_IP"

# Wait for SSH to be available
echo "Waiting for SSH to become available..."
for i in {1..30}; do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP} "echo 'SSH ready'" 2>/dev/null; then
        break
    fi
    echo "  Attempt $i/30 - waiting for SSH..."
    sleep 10
done

# Update hosts file
echo "Updating Ansible hosts file..."
HOSTS_FILE="$PROVISIONING_DIR/hosts"

# Check if test section exists
if grep -q "^\[test\]" "$HOSTS_FILE"; then
    # Update existing entry
    sed -i.bak "/^\[test\]/,/^\[/{ s/ansible_host=.*/ansible_host=$PUBLIC_IP ansible_user=ubuntu ansible_python_interpreter=\/usr\/bin\/python3/ }" "$HOSTS_FILE"
else
    # Add new test section
    echo "" >> "$HOSTS_FILE"
    echo "[test]" >> "$HOSTS_FILE"
    echo "regluit-test ansible_host=$PUBLIC_IP ansible_user=ubuntu ansible_python_interpreter=/usr/bin/python3" >> "$HOSTS_FILE"
fi

# Save instance metadata for tear-down
METADATA_FILE="$PROVISIONING_DIR/.test-instance"
cat > "$METADATA_FILE" << EOF
INSTANCE_ID=$INSTANCE_ID
INSTANCE_NAME=$INSTANCE_NAME
PUBLIC_IP=$PUBLIC_IP
REGION=$REGION
KEY_NAME=$KEY_NAME
CREATED_AT=$(date -Iseconds)
WITH_RDS=$WITH_RDS
EOF

echo ""
echo "=== Test Environment Ready ==="
echo ""
echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo "SSH Command: ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP}"
echo ""
echo "Next steps:"
echo "  1. Run the Ansible playbook:"
echo "     ansible-playbook -i hosts setup-test.yml --ask-vault-pass"
echo ""
echo "  2. To tear down the environment:"
echo "     ./scripts/tear-down-test.sh"
echo ""

if $WITH_RDS; then
    echo "RDS cloning was requested but is not yet implemented."
    echo "Manual steps required to clone production database."
fi

echo "Estimated daily cost: \$0.35-0.65 (EC2 only)"
