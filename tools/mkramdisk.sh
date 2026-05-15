#!/bin/bash
# mkramdisk.sh — Build a simple ramdisk archive from a directory of files.
# Format:
#   Header: magic[4]="MRD\0", file_count:u32, reserved[3]u32
#   Entries: { name[64]u8, offset:u64, size:u64 } × file_count
#   Data: raw file bytes concatenated

set -e

INPUT_DIR="$1"
OUTPUT="$2"

if [ -z "$INPUT_DIR" ] || [ -z "$OUTPUT" ]; then
    echo "Usage: $0 <input_dir> <output_file>"
    exit 1
fi

if [ ! -d "$INPUT_DIR" ]; then
    echo "Error: $INPUT_DIR is not a directory"
    exit 1
fi

# Collect files
FILES=()
for f in "$INPUT_DIR"/*; do
    [ -f "$f" ] || continue
    FILES+=("$f")
done

FILE_COUNT=${#FILES[@]}

if [ "$FILE_COUNT" -eq 0 ]; then
    echo "Error: no files in $INPUT_DIR"
    exit 1
fi

if [ "$FILE_COUNT" -gt 32 ]; then
    echo "Error: too many files ($FILE_COUNT > 32)"
    exit 1
fi

# Calculate sizes
HEADER_SIZE=32  # 4 + 4 + 12 = 20, padded to 32 for alignment
ENTRY_SIZE=80   # 64 + 8 + 8 = 80
ENTRIES_SIZE=$((ENTRY_SIZE * FILE_COUNT))
DATA_OFFSET=$((HEADER_SIZE + ENTRIES_SIZE))

# Temporary files
HEADER_TMP=$(mktemp)
ENTRIES_TMP=$(mktemp)
DATA_TMP=$(mktemp)
trap "rm -f $HEADER_TMP $ENTRIES_TMP $DATA_TMP" EXIT

# Write header: "MRD\0" + file_count (little-endian u32) + 3 reserved u32s
printf 'MRD\0' > "$HEADER_TMP"
# file_count as u32 LE
printf "\\$(printf '%03o' $((FILE_COUNT & 0xFF)))" >> "$HEADER_TMP"
printf "\\$(printf '%03o' $(((FILE_COUNT >> 8) & 0xFF)))" >> "$HEADER_TMP"
printf "\\$(printf '%03o' $(((FILE_COUNT >> 16) & 0xFF)))" >> "$HEADER_TMP"
printf "\\$(printf '%03o' $(((FILE_COUNT >> 24) & 0xFF)))" >> "$HEADER_TMP"
# 3 reserved u32s (12 bytes of zeros)
dd if=/dev/zero bs=1 count=12 >> "$HEADER_TMP" 2>/dev/null
# Pad to HEADER_SIZE (32 bytes total = 4+4+12 = 20, need 12 more)
CURRENT=$(stat -c%s "$HEADER_TMP")
PAD=$((HEADER_SIZE - CURRENT))
if [ "$PAD" -gt 0 ]; then
    dd if=/dev/zero bs=1 count="$PAD" >> "$HEADER_TMP" 2>/dev/null
fi

# Write entries and collect data
> "$ENTRIES_TMP"
> "$DATA_TMP"

DATA_OFFSET_CURRENT=0
for f in "${FILES[@]}"; do
    BASENAME=$(basename "$f")
    FILE_SIZE=$(stat -c%s "$f")

    # Check name length
    NAME_LEN=${#BASENAME}
    if [ "$NAME_LEN" -gt 63 ]; then
        echo "Error: filename too long: $BASENAME"
        exit 1
    fi

    # Write entry: name[64] + offset(u64 LE) + size(u64 LE)
    # Name (64 bytes, null-padded)
    printf '%s' "$BASENAME" >> "$ENTRIES_TMP"
    PAD_NAME=$((64 - NAME_LEN))
    dd if=/dev/zero bs=1 count="$PAD_NAME" >> "$ENTRIES_TMP" 2>/dev/null

    # Offset (u64 LE)
    OFF_VAL=$DATA_OFFSET_CURRENT
    for i in 0 1 2 3 4 5 6 7; do
        BYTE=$(( (OFF_VAL >> (i * 8)) & 0xFF ))
        printf "\\$(printf '%03o' $BYTE)" >> "$ENTRIES_TMP"
    done

    # Size (u64 LE)
    for i in 0 1 2 3 4 5 6 7; do
        BYTE=$(( (FILE_SIZE >> (i * 8)) & 0xFF ))
        printf "\\$(printf '%03o' $BYTE)" >> "$ENTRIES_TMP"
    done

    # Append file data
    cat "$f" >> "$DATA_TMP"

    DATA_OFFSET_CURRENT=$((DATA_OFFSET_CURRENT + FILE_SIZE))

    echo "  Added: $BASENAME ($FILE_SIZE bytes)"
done

# Combine: header + entries + data
cat "$HEADER_TMP" "$ENTRIES_TMP" "$DATA_TMP" > "$OUTPUT"

TOTAL_SIZE=$(stat -c%s "$OUTPUT")
echo "Ramdisk: $FILE_COUNT files, $TOTAL_SIZE bytes -> $OUTPUT"
