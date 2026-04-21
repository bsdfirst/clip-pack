#!/bin/bash
set -euo pipefail

AUTO_YES=false
WATCH=false
FILTER_ID=""

usage() {
    echo "Usage: $(basename "$0") [-y] [-w] [-i ID]"
    echo ""
    echo "Unpack a clip-pack transfer from the clipboard into the current directory."
    echo ""
    echo "Options:"
    echo "  -y              Skip all confirmation prompts"
    echo "  -w, --watch     Continuously poll clipboard for new transfers"
    echo "  -i, --id ID     Only accept transfers with this ID (ignore others)"
    echo "  -h, --help      Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y)         AUTO_YES=true; shift ;;
        -w|--watch) WATCH=true; shift ;;
        -i|--id)
            [[ -z "${2:-}" ]] && { echo "ERROR: --id requires a value" >&2; exit 1; }
            FILTER_ID="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "$(uname -s)" in
    Darwin)
        sha256_file()    { shasum -a 256 "$1" | cut -d' ' -f1; }
        read_clipboard() { pbpaste | tr -d '\r'; }
        copy_to_clip()   { pbcopy; }
        base64_decode()  { base64 -D; }
        ;;
    *)
        sha256_file()    { sha256sum "$1" | cut -d' ' -f1; }
        read_clipboard() { powershell.exe -NoProfile -NonInteractive -NoLogo -Command "[Console]::Out.Write((Get-Clipboard -Raw))" 2>/dev/null | tr -d '\r'; }
        copy_to_clip()   { clip.exe; }
        base64_decode()  { base64 -d; }
        ;;
esac

CURRENT=$(pwd -P)
if [ "$CURRENT" = "$HOME" ] || [ "$CURRENT" = "/" ]; then
    echo "ERROR: Refusing to unpack into ${CURRENT}. Use a subdirectory."
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Parse a clipboard dump file into header variables and a data file.
#
# Sets globals: HDR_TRANSFER_ID, HDR_CHUNK, HDR_TOTAL,
#               HDR_CHUNK_SHA256, HDR_TAR_SHA256
# Writes base64 payload to $WORK/chunk_data.b64
# ---------------------------------------------------------------------------
parse_header() {
    local file="$1"

    if ! head -1 "$file" | grep -q '^CLIP-PACK-V1$'; then
        return 1
    fi

    local sep_line
    sep_line=$(grep -n '^---$' "$file" | head -1 | cut -d: -f1)
    [ -z "$sep_line" ] && return 1

    local header
    header=$(sed -n '2,'"$((sep_line - 1))"'p' "$file")

    HDR_TRANSFER_ID=$(echo "$header" | grep '^transfer-id=' | cut -d= -f2)
    HDR_CHUNK=$(echo "$header" | grep '^chunk=' | cut -d= -f2)
    HDR_TOTAL=$(echo "$header" | grep '^total=' | cut -d= -f2)
    HDR_CHUNK_SHA256=$(echo "$header" | grep '^chunk-sha256=' | cut -d= -f2)
    HDR_TAR_SHA256=$(echo "$header" | grep '^tar-sha256=' | cut -d= -f2)

    if [ -z "$HDR_TRANSFER_ID" ]; then
        echo "ERROR: Transfer header is missing transfer-id." >&2
        return 1
    fi
    if [[ ! "$HDR_CHUNK" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Transfer header has invalid or missing chunk index." >&2
        return 1
    fi
    if [[ ! "$HDR_TOTAL" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Transfer header has invalid or missing total chunk count." >&2
        return 1
    fi
    if [ "$HDR_CHUNK" -gt "$HDR_TOTAL" ]; then
        echo "ERROR: Header chunk index (${HDR_CHUNK}) exceeds total (${HDR_TOTAL})." >&2
        return 1
    fi
    if [ "${#HDR_CHUNK_SHA256}" -ne 64 ] || ! grep -Eq '^[a-fA-F0-9]{64}$' <<< "$HDR_CHUNK_SHA256"; then
        echo "ERROR: Transfer header has invalid chunk-sha256 (expected 64 hex characters)." >&2
        return 1
    fi
    if [ "${#HDR_TAR_SHA256}" -ne 64 ] || ! grep -Eq '^[a-fA-F0-9]{64}$' <<< "$HDR_TAR_SHA256"; then
        echo "ERROR: Transfer header has invalid tar-sha256 (expected 64 hex characters)." >&2
        return 1
    fi

    tail -n +$((sep_line + 1)) "$file" | tr -d '\r\n' > "$WORK/chunk_data.b64"
    return 0
}

# ---------------------------------------------------------------------------
# Verify the current chunk's checksum against the header value.
# ---------------------------------------------------------------------------
verify_chunk() {
    local actual
    actual=$(sha256_file "$WORK/chunk_data.b64")
    if [ "$actual" != "$HDR_CHUNK_SHA256" ]; then
        echo "ERROR: Chunk ${HDR_CHUNK} checksum mismatch!"
        echo "  Expected: $HDR_CHUNK_SHA256"
        echo "  Got:      $actual"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Write an acknowledgement to the clipboard so the pack side knows to proceed.
# ---------------------------------------------------------------------------
send_ack() {
    local tid="$1" chunk_num="$2"
    {
        echo "CLIP-PACK-ACK"
        echo "transfer-id=$tid"
        echo "chunk=$chunk_num"
        echo "---"
    } | copy_to_clip
}

# ---------------------------------------------------------------------------
# Receive a complete transfer (single or multi-chunk).
#
# On success, sets globals: RESULT_TAR, RESULT_TRANSFER_ID
# ---------------------------------------------------------------------------
receive_transfer() {
    rm -rf "$WORK/chunks"
    mkdir -p "$WORK/chunks"

    read_clipboard > "$WORK/clipboard.raw"

    if ! parse_header "$WORK/clipboard.raw"; then
        echo "ERROR: Clipboard does not contain a valid clip-pack transfer."
        return 1
    fi
    if [ -n "$FILTER_ID" ] && [ "$HDR_TRANSFER_ID" != "$FILTER_ID" ]; then
        echo "Ignoring transfer ${HDR_TRANSFER_ID} (waiting for ID: ${FILTER_ID})."
        return 1
    fi
    if ! verify_chunk; then
        return 1
    fi
    if [ "$HDR_CHUNK" != "1" ]; then
        echo "ERROR: A new transfer must begin with chunk 1 (got chunk ${HDR_CHUNK})." >&2
        return 1
    fi

    local transfer_id="$HDR_TRANSFER_ID"
    local total="$HDR_TOTAL"
    local tar_sha256="$HDR_TAR_SHA256"

    cp "$WORK/chunk_data.b64" "$WORK/chunks/1.b64"
    echo -e "Received chunk 1/${total} — checksum \033[36mOK\033[0m"

    if [ "$total" -gt 1 ]; then
        send_ack "$transfer_id" 1

        local received=1
        while [ "$received" -lt "$total" ]; do
            local expected=$((received + 1))
            printf "Waiting for chunk %d/%d..." "$expected" "$total"

            while true; do
                sleep 1

                if ! read_clipboard > "$WORK/clipboard.raw" 2>/dev/null; then
                    printf "."
                    continue
                fi
                if ! parse_header "$WORK/clipboard.raw" 2>/dev/null; then
                    printf "."
                    continue
                fi

                if [ "$HDR_TRANSFER_ID" = "$transfer_id" ]; then
                    if [ "$HDR_CHUNK" = "$expected" ]; then
                        if ! verify_chunk; then
                            return 1
                        fi
                        cp "$WORK/chunk_data.b64" "$WORK/chunks/${expected}.b64"
                        received=$expected
                        echo ""
                        echo -e "Received chunk ${received}/${total} — checksum \033[36mOK\033[0m"
                        send_ack "$transfer_id" "$received"
                        break
                    elif [ "$HDR_CHUNK" -lt "$expected" ] && \
                         [ -f "$WORK/chunks/${HDR_CHUNK}.b64" ]; then
                        if ! verify_chunk; then
                            printf "."
                            continue
                        fi
                        send_ack "$transfer_id" "$HDR_CHUNK"
                        printf "."
                        continue
                    fi
                fi

                printf "."
            done
        done
    fi

    # Reassemble chunks, decode, and decompress
    local i
    for i in $(seq 1 "$total"); do
        cat "$WORK/chunks/${i}.b64"
    done | base64_decode | xz -d > "$WORK/archive.tar"

    local actual_tar_sha256
    actual_tar_sha256=$(sha256_file "$WORK/archive.tar")
    echo ""
    echo -e "Checksum (tar): \033[36m${actual_tar_sha256}\033[0m"

    if [ "$actual_tar_sha256" != "$tar_sha256" ]; then
        echo "ERROR: Tar checksum mismatch!"
        echo "  Expected: $tar_sha256"
        echo "  Got:      $actual_tar_sha256"
        return 1
    fi
    echo "Checksum verified OK."

    RESULT_TAR="$WORK/archive.tar"
    RESULT_TRANSFER_ID="$transfer_id"
}

# ---------------------------------------------------------------------------
# Replace the current directory contents with the received archive.
# ---------------------------------------------------------------------------
extract_archive() {
    find . -mindepth 1 -delete 2>/dev/null || true
    tar xf "$RESULT_TAR"
    local file_count
    file_count=$(find . -mindepth 1 -type f | wc -l | tr -d ' ')
    echo "Done. Extracted ${file_count} files."
}

# ===========================================================================
# Main
# ===========================================================================

if [ "$WATCH" = true ]; then
    echo "Unpacking clipboard into: $(pwd)"
    if [ -n "$FILTER_ID" ]; then
        echo "Filtering for transfer ID: ${FILTER_ID}"
    fi
    echo "Watch mode: polling clipboard every second. Press Ctrl+C to stop."
    echo ""

    LAST_SEEN_KEY=""
    trap 'echo ""; echo "Watch mode stopped."; exit 0' INT

    while true; do
        if read_clipboard > "$WORK/clipboard.raw" 2>/dev/null && \
           parse_header "$WORK/clipboard.raw" 2>/dev/null; then

            if [ -n "$FILTER_ID" ] && [ "$HDR_TRANSFER_ID" != "$FILTER_ID" ]; then
                sleep 1
                continue
            fi

            CURRENT_KEY="${HDR_TRANSFER_ID}:${HDR_TAR_SHA256}"

            if [ -n "$HDR_TRANSFER_ID" ] && \
               [ "$CURRENT_KEY" != "$LAST_SEEN_KEY" ]; then

                echo "New transfer detected (${HDR_TRANSFER_ID})."
                echo ""

                if receive_transfer; then
                    if [ "$AUTO_YES" = false ]; then
                        read -rp "Replace current directory contents? [y/N] " -n 1
                        echo ""
                        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                            echo "Skipped."
                            LAST_SEEN_KEY="$CURRENT_KEY"
                            echo ""
                            echo "Watching for next transfer..."
                            continue
                        fi
                    fi
                    extract_archive
                    LAST_SEEN_KEY="$CURRENT_KEY"
                else
                    echo "Transfer failed. Will retry on next change."
                    LAST_SEEN_KEY="$CURRENT_KEY"
                fi

                echo ""
                echo "Watching for next transfer..."
            fi
        fi

        sleep 1
    done

else
    echo "Unpacking clipboard into: $(pwd)"
    if [ -n "$FILTER_ID" ]; then
        echo "Filtering for transfer ID: ${FILTER_ID}"
    fi
    echo ""

    echo "This will REPLACE the contents of the current directory."
    if [ "$AUTO_YES" = false ]; then
        read -rp "Continue? [y/N] " -n 1
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    fi

    receive_transfer || exit 1

    if [ "$AUTO_YES" = false ]; then
        echo ""
        echo "Verify this matches the checksum from the sending side."
        read -rp "Checksums match? Continue extracting? [y/N] " -n 1
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    fi

    extract_archive
fi
