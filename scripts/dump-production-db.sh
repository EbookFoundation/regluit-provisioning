#!/bin/bash
#
# dump-production-db.sh - Create a sanitized dump of the production database
#
# This script connects to production (via SSH) and creates a database dump
# suitable for use in test/development environments.
#
# Usage: ./dump-production-db.sh [--full|--sanitized] [--output <path>]
#
# Options:
#   --full        Full dump without sanitization (default)
#   --sanitized   Sanitize sensitive data (emails, passwords, etc.)
#   --output      Output path for the dump file (default: ./dumps/)
#
# The script assumes you have SSH access to the production server.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONING_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
PROD_HOST="${PROD_HOST:-unglue.it}"
PROD_USER="${PROD_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROVISIONING_DIR/dumps}"
DUMP_TYPE="full"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --full)
            DUMP_TYPE="full"
            shift
            ;;
        --sanitized)
            DUMP_TYPE="sanitized"
            shift
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--full|--sanitized] [--output <path>]"
            echo ""
            echo "Options:"
            echo "  --full        Full dump without sanitization (default)"
            echo "  --sanitized   Sanitize sensitive data"
            echo "  --output      Output directory (default: ./dumps/)"
            echo ""
            echo "Environment variables:"
            echo "  PROD_HOST     Production hostname (default: unglue.it)"
            echo "  PROD_USER     SSH user (default: ubuntu)"
            echo "  SSH_KEY       Path to SSH key (optional)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=== Production Database Dump ==="
echo "Type: $DUMP_TYPE"
echo "Output: $OUTPUT_DIR"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Build SSH command
SSH_CMD="ssh"
if [[ -n "$SSH_KEY" ]]; then
    SSH_CMD="$SSH_CMD -i $SSH_KEY"
fi
SSH_CMD="$SSH_CMD $PROD_USER@$PROD_HOST"

# Check SSH connectivity
echo "Checking SSH connectivity to production..."
if ! $SSH_CMD "echo 'Connection successful'" 2>/dev/null; then
    echo "Error: Cannot connect to $PROD_HOST"
    echo "Ensure you have SSH access configured."
    exit 1
fi

# Create dump on production server
echo "Creating database dump on production server..."
REMOTE_DUMP="/tmp/regluit-dump-${TIMESTAMP}.sql"

$SSH_CMD << 'ENDSSH'
cd /opt/regluit
source venv/bin/activate

# Get database credentials from Django settings
DB_NAME=$(python -c "from django.conf import settings; print(settings.DATABASES['default']['NAME'])")
DB_USER=$(python -c "from django.conf import settings; print(settings.DATABASES['default']['USER'])")
DB_HOST=$(python -c "from django.conf import settings; print(settings.DATABASES['default']['HOST'])")

echo "Dumping database: $DB_NAME"

mysqldump --hex-blob \
    --host="$DB_HOST" \
    --user="$DB_USER" \
    --single-transaction \
    --no-tablespaces \
    --column-statistics=0 \
    --set-gtid-purged=OFF \
    "$DB_NAME" > /tmp/regluit-dump-TIMESTAMP.sql

echo "Dump complete: $(du -h /tmp/regluit-dump-TIMESTAMP.sql | cut -f1)"
ENDSSH

# Fix the timestamp in the remote command
$SSH_CMD "mv /tmp/regluit-dump-TIMESTAMP.sql $REMOTE_DUMP" 2>/dev/null || true

# Download the dump
LOCAL_DUMP="$OUTPUT_DIR/regluit-${DUMP_TYPE}-${TIMESTAMP}.sql"
echo "Downloading dump to local machine..."
scp ${SSH_KEY:+-i $SSH_KEY} "$PROD_USER@$PROD_HOST:$REMOTE_DUMP" "$LOCAL_DUMP"

# Clean up remote dump
echo "Cleaning up remote dump..."
$SSH_CMD "rm -f $REMOTE_DUMP"

# Sanitize if requested
if [[ "$DUMP_TYPE" == "sanitized" ]]; then
    echo "Sanitizing dump..."
    SANITIZED_DUMP="$OUTPUT_DIR/regluit-sanitized-${TIMESTAMP}.sql"

    # Create sanitization SQL
    cat > /tmp/sanitize.sed << 'EOF'
# Sanitize email addresses (replace domain with example.com, keep local part hash)
s/('[^']*@)[^']*'/\1example.com'/g

# Replace password hashes with a known test hash (password: 'testpassword123')
s/'pbkdf2_sha256\$[^']*'/'pbkdf2_sha256$320000$testsalt$testhash'/g
EOF

    sed -f /tmp/sanitize.sed "$LOCAL_DUMP" > "$SANITIZED_DUMP"
    rm -f /tmp/sanitize.sed
    rm -f "$LOCAL_DUMP"
    LOCAL_DUMP="$SANITIZED_DUMP"

    echo "Sanitization complete."
fi

# Compress the dump
echo "Compressing dump..."
gzip -f "$LOCAL_DUMP"
LOCAL_DUMP="${LOCAL_DUMP}.gz"

echo ""
echo "=== Dump Complete ==="
echo "File: $LOCAL_DUMP"
echo "Size: $(du -h "$LOCAL_DUMP" | cut -f1)"
echo ""
echo "To import into a local MySQL database:"
echo "  gunzip -c $LOCAL_DUMP | mysql -u root -p regluit_test"
echo ""
echo "For Docker setup:"
echo "  cp $LOCAL_DUMP docker/initdb/"
