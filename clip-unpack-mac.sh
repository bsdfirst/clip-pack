#!/bin/bash
set -euo pipefail

AUTO_YES=false
while getopts "y" opt; do
    case $opt in
        y) AUTO_YES=true ;;
        *) echo "Usage: $0 [-y]"; exit 1 ;;
    esac
done

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
if [ "$AUTO_YES" = false ]; then
    read -p "Continue? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Decode, decompress, and checksum before extracting
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

pbpaste | tr -d '\r\n' | base64 -d | xz -d > "$TMPDIR/archive.tar"

CHECKSUM=$(shasum -a 256 "$TMPDIR/archive.tar" | cut -d' ' -f1)
echo -e "Checksum (tar): \033[36m${CHECKSUM}\033[0m"
if [ "$AUTO_YES" = false ]; then
    echo ""
    echo "Verify this matches the checksum from the sending side."
    read -p "Checksums match? Continue extracting? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Clean current directory and extract
find . -mindepth 1 -delete 2>/dev/null || true
tar xf "$TMPDIR/archive.tar"

FILE_COUNT=$(find . -mindepth 1 -type f | wc -l | tr -d ' ')
echo "Done. Extracted ${FILE_COUNT} files."
