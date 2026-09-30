#!/usr/bin/env bash
# check-no-plaintext-keys.sh
#
# Pre-commit hook that rejects files containing PEM private keys unless
# the file is ansible-vault encrypted.
#
# Called by .pre-commit-config.yaml. Receives file paths as arguments.
#
# Why this exists: security-private#10 (April 2026). A Claude Code session
# committed an unencrypted wildcard TLS private key to this public repo,
# breaking the established convention of ansible-vault encrypting all keys
# in private/. This hook is one of several layered controls to prevent
# recurrence. The strongest control (GitHub Secret Scanning with Push
# Protection) catches pushes server-side; this hook catches locally before
# you even try to push.

set -euo pipefail

EXIT_CODE=0

# ansible-vault 1.1/1.2 header; 1.2 appends ';<vault-id>'.
VAULT_HEADER_RE='^\$ANSIBLE_VAULT;1\.[12];AES256(;.*)?$'

for file in "$@"; do
    # Skip files that don't exist (deletions)
    [ -f "$file" ] || continue

    # Read first line
    first_line=$(head -n 1 "$file" 2>/dev/null || echo "")

    # Files with a valid ansible-vault header are encrypted — allowed.
    # Match the full header, not just the prefix, so a first line like
    # "$ANSIBLE_VAULT_NOT_REALLY" doesn't exempt a plaintext key below it.
    if [[ "$first_line" =~ $VAULT_HEADER_RE ]]; then
        continue
    fi

    # Check for PEM private key markers anywhere in the file.
    # Matches RSA, EC, DSA, OPENSSH, ENCRYPTED, etc.
    if grep -qE -- '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' "$file"; then
        echo "ERROR: $file contains a PEM private key but is not ansible-vault encrypted." >&2
        echo "" >&2
        echo "  To fix:" >&2
        echo "    ansible-vault encrypt \"$file\"" >&2
        echo "" >&2
        echo "  To bypass (strongly discouraged; requires justification):" >&2
        echo "    git commit --no-verify" >&2
        echo "" >&2
        echo "  See: EbookFoundation/security-private#10" >&2
        EXIT_CODE=1
    fi
done

exit $EXIT_CODE
