#!/bin/bash
set -euo pipefail

CHUNK_SIZE_MB=50
USER_TRANSFER_ID=""

usage() {
    echo "Usage: $(basename "$0") [-s SIZE_MB] [-i ID]"
    echo ""
    echo "Pack the current directory onto the clipboard."
    echo ""
    echo "Options:"
    echo "  -s, --size SIZE_MB  Chunk size threshold in MB (default: 50)"
    echo "  -i, --id ID         Set a transfer ID (default: random)"
    echo "  -h, --help          Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--size)
            [[ -z "${2:-}" ]] && { echo "ERROR: --size requires a value" >&2; exit 1; }
            CHUNK_SIZE_MB="$2"
            shift 2
            ;;
        -i|--id)
            [[ -z "${2:-}" ]] && { echo "ERROR: --id requires a value" >&2; exit 1; }
            USER_TRANSFER_ID="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ ! "$CHUNK_SIZE_MB" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --size must be a positive integer (megabytes)." >&2
    exit 1
fi
if [ "$CHUNK_SIZE_MB" -gt 8192 ]; then
    echo "ERROR: --size exceeds maximum (8192 MB)." >&2
    exit 1
fi

CHUNK_SIZE_BYTES=$((CHUNK_SIZE_MB * 1024 * 1024))

case "$(uname -s)" in
    Darwin)
        sha256_file()    { shasum -a 256 "$1" | cut -d' ' -f1; }
        sha256_stdin()   { shasum -a 256 | cut -d' ' -f1; }
        copy_to_clip()   { pbcopy; }
        read_clipboard() { pbpaste | tr -d '\r'; }
        tar_create()     { COPYFILE_DISABLE=1 tar cf - --no-xattrs --exclude='.DS_Store' .; }
        base64_encode()  { base64 | tr -d '\n'; }
        ;;
    *)
        sha256_file()    { sha256sum "$1" | cut -d' ' -f1; }
        sha256_stdin()   { sha256sum | cut -d' ' -f1; }
        copy_to_clip()   { clip.exe; }
        read_clipboard() { powershell.exe -NoProfile -NonInteractive -NoLogo -Command "[Console]::Out.Write((Get-Clipboard -Raw))" 2>/dev/null | tr -d '\r'; }
        tar_create()     { tar cf - .; }
        base64_encode()  { base64 -w0; }
        ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Packing current directory: $(pwd)"
echo ""
echo "Compressing and encoding..."

CKSUM_FIFO="$WORK/cksum.fifo"
mkfifo "$CKSUM_FIFO"
sha256_stdin < "$CKSUM_FIFO" > "$WORK/tar-sha256.txt" &
HASH_PID=$!

tar_create | tee "$CKSUM_FIFO" | xz -9e | base64_encode > "$WORK/payload.b64"

wait "$HASH_PID"
TAR_SHA256=$(cat "$WORK/tar-sha256.txt")

PAYLOAD_SIZE=$(wc -c < "$WORK/payload.b64" | tr -d ' ')
if [ -n "$USER_TRANSFER_ID" ]; then
    TRANSFER_ID="$USER_TRANSFER_ID"
else
    TRANSFER_ID=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi

if [ "$PAYLOAD_SIZE" -le "$CHUNK_SIZE_BYTES" ]; then
    TOTAL_CHUNKS=1
else
    split -b "$CHUNK_SIZE_BYTES" "$WORK/payload.b64" "$WORK/chunk_"
    TOTAL_CHUNKS=0
    for _ in "$WORK"/chunk_*; do TOTAL_CHUNKS=$((TOTAL_CHUNKS + 1)); done
fi

send_chunk() {
    local chunk_file="$1" chunk_num="$2"
    local chunk_sha256 chunk_size chunk_mb
    chunk_sha256=$(sha256_file "$chunk_file")
    chunk_size=$(wc -c < "$chunk_file" | tr -d ' ')
    chunk_mb=$(echo "scale=1; $chunk_size / 1024 / 1024" | bc)

    {
        echo "CLIP-PACK-V1"
        echo "transfer-id=$TRANSFER_ID"
        echo "chunk=$chunk_num"
        echo "total=$TOTAL_CHUNKS"
        echo "chunk-sha256=$chunk_sha256"
        echo "tar-sha256=$TAR_SHA256"
        echo "---"
        cat "$chunk_file"
    } | tee "$WORK/last_sent_payload" | copy_to_clip

    echo -e "Sent chunk ${chunk_num}/${TOTAL_CHUNKS} (${chunk_mb} MB) — checksum: \033[36m${chunk_sha256}\033[0m"
}

wait_for_ack() {
    local expected_chunk="$1" chunk_file="$2"
    local clip_lost_at=""
    printf "Waiting for acknowledgement of chunk %d..." "$expected_chunk"
    while true; do
        sleep 1
        if ! read_clipboard > "$WORK/ack.raw" 2>/dev/null; then
            printf "."
            continue
        fi
        if head -1 "$WORK/ack.raw" | grep -q '^CLIP-PACK-ACK$' && \
           grep -q "^transfer-id=${TRANSFER_ID}$" "$WORK/ack.raw" && \
           grep -q "^chunk=${expected_chunk}$" "$WORK/ack.raw"; then
            echo " OK"
            return 0
        fi
        if cmp -s "$WORK/ack.raw" "$WORK/last_sent_payload" 2>/dev/null; then
            clip_lost_at=""
        else
            if [ -z "$clip_lost_at" ]; then
                clip_lost_at=$(date +%s)
            elif [ "$(($(date +%s) - clip_lost_at))" -ge 10 ]; then
                echo ""
                echo "Clipboard no longer holds chunk ${expected_chunk}; no ACK after 10s — resending."
                send_chunk "$chunk_file" "$expected_chunk"
                clip_lost_at=""
            fi
        fi
        printf "."
    done
}

if [ "$TOTAL_CHUNKS" -eq 1 ]; then
    send_chunk "$WORK/payload.b64" 1
else
    CHUNK_NUM=0
    for chunk_file in "$WORK"/chunk_*; do
        CHUNK_NUM=$((CHUNK_NUM + 1))
        send_chunk "$chunk_file" "$CHUNK_NUM"
        wait_for_ack "$CHUNK_NUM" "$chunk_file"
    done
fi

PAYLOAD_MB=$(echo "scale=2; $PAYLOAD_SIZE / 1024 / 1024" | bc)
echo ""
echo "Total payload: ${PAYLOAD_MB} MB (base64 encoded), ${TOTAL_CHUNKS} chunk(s)"
echo -e "Checksum (tar): \033[36m${TAR_SHA256}\033[0m"
echo ""
if [ "$TOTAL_CHUNKS" -gt 1 ]; then
    echo "On the remote end, verify the tar checksum after all chunks are received."
else
    echo "On the remote end, verify with this checksum."
fi
