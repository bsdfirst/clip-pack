#!/bin/bash
set -euo pipefail

WARN_SIZE_MB=60
WARN_SIZE_BYTES=$((WARN_SIZE_MB * 1024 * 1024))

echo "Packing current directory: $(pwd)"
echo ""

# Create tar and capture checksum
TAR_DATA=$(COPYFILE_DISABLE=1 tar cf - --no-xattrs --exclude='.DS_Store' . | tee >(shasum -a 256 | cut -d' ' -f1 > /tmp/clip-pack-checksum.txt) | xz -9e | base64)

CHECKSUM=$(cat /tmp/clip-pack-checksum.txt)
rm -f /tmp/clip-pack-checksum.txt

# Check encoded size
ENCODED_SIZE=${#TAR_DATA}

if [ "$ENCODED_SIZE" -gt "$WARN_SIZE_BYTES" ]; then
    ENCODED_MB=$(echo "scale=1; $ENCODED_SIZE / 1024 / 1024" | bc)
    echo "WARNING: Encoded payload is ${ENCODED_MB} MB (limit: ${WARN_SIZE_MB} MB)"
    echo "This may exceed the Citrix clipboard limit."
    echo ""
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo "$TAR_DATA" | pbcopy

ENCODED_MB=$(echo "scale=2; $ENCODED_SIZE / 1024 / 1024" | bc)
echo "Copied to clipboard: ${ENCODED_MB} MB (base64 encoded)"
echo -e "Checksum (tar): \033[36m${CHECKSUM}\033[0m"
echo ""
echo "On the remote end, verify with this checksum."
