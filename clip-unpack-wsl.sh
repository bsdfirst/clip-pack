#!/bin/bash
set -euo pipefail

echo "Unpacking clipboard into: $(pwd)"
echo ""

# Safety check — refuse to unpack into home directory or root
CURRENT=$(pwd -P)
if [ "$CURRENT" = "$HOME" ] || [ "$CURRENT" = "/" ]; then
    echo "ERROR: Refusing to unpack into ${CURRENT}. Use a subdirectory."
    exit 1
fi

# Confirm destructive operation
echo "This will REPLACE the contents of the current directory."
read -p "Continue? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Decode, decompress, and checksum before extracting
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

powershell.exe -Command "[Console]::Out.Write((Get-Clipboard -Raw))" | tr -d '\r\n' | base64 -d | xz -d > "$TMPDIR/archive.tar"

CHECKSUM=$(sha256sum "$TMPDIR/archive.tar" | cut -d' ' -f1)
echo "Checksum (tar): ${CHECKSUM}"
echo ""
echo "Verify this matches the checksum from the sending side."
read -p "Checksums match? Continue extracting? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Clean current directory and extract
find . -mindepth 1 -delete 2>/dev/null || true
tar xf "$TMPDIR/archive.tar"

FILE_COUNT=$(find . -mindepth 1 -type f | wc -l | tr -d ' ')
echo "Done. Extracted ${FILE_COUNT} files."
