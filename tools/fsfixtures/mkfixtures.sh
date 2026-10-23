#!/bin/bash
# Regenerate the ext4 / NTFS fixture images used by the host tests and the
# QEMU smoke. Needs e2fsprogs (mke2fs) and ntfs-3g (mkntfs, ntfscp).
# Output is deterministic in content; images are small and compress well.
set -euo pipefail
OUT="${1:-$(cd "$(dirname "$0")" && pwd)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK" <<'PY'
import os, sys
root = os.path.join(sys.argv[1], "src")
os.makedirs(root + "/dir/sub", exist_ok=True)
os.makedirs(root + "/perm/locked", exist_ok=True)
os.makedirs(root + "/perm/listonly", exist_ok=True)
w = lambda p, d: open(os.path.join(root, p), "wb").write(d if isinstance(d, bytes) else d.encode())
w("small.txt", "hello fs\n")
w("big.bin", bytes((i * 7 + i // 251) & 0xFF for i in range(300000)))
for i in range(1, 301):
    w(f"dir/file_{i}.txt", f"{i}\n")
w("dir/sub/n.txt", "nested\n")
os.symlink("small.txt", root + "/link")
with open(root + "/sparse.bin", "wb") as f:
    for k in range(24):
        f.seek(k * 16384); f.write(bytes([65 + k % 26]) * 100)
    f.seek(24 * 16384 + 5000); f.write(b"END")
w("empty.txt", "")
# Permission fixtures: files are created readable here (mke2fs -d must read
# them); the modes and owners are applied to the finished image below.
w("perm/private.txt", "owner only\n")
w("perm/group.txt", "group readable\n")
w("perm/world.txt", "world readable\n")
w("perm/locked/inside.txt", "behind a closed door\n")
w("perm/listonly/inside.txt", "listable but not searchable\n")
w("perm/mine_closed.txt", "owner class denies, other class would allow\n")
w("perm/mine_open.txt", "mine and readable\n")
PY

# ext4 (extents, 64bit, flex_bg, metadata_csum, journal) with 1 KiB blocks, then
# e2fsck -D so /dir becomes a real htree (dir_index) directory.
truncate -s 4M "$OUT/ext4_1k.img"
mke2fs -q -t ext4 -b 1024 -N 1024 -L MOQIEXT4 -U 11111111-2222-3333-4444-555555555555 \
    -E hash_seed=11111111-2222-3333-4444-555555555555 -d "$WORK/src" "$OUT/ext4_1k.img"
e2fsck -fyD "$OUT/ext4_1k.img" >/dev/null 2>&1 || true
# Set the /perm modes and hand most files to another owner so a process running as the build user
# (uid/gid 1000, the test program's identity) lands in the "other" class for
# them. mine_* keep owner 1000. debugfs rewrites the inodes in place.
debugfs -w -f - "$OUT/ext4_1k.img" >/dev/null 2>&1 <<'DBG'
sif /perm/private.txt mode 0100600
sif /perm/group.txt mode 0100640
sif /perm/world.txt mode 0100644
sif /perm/locked mode 040700
sif /perm/listonly mode 040744
sif /perm/mine_closed.txt mode 0100044
sif /perm/mine_open.txt mode 0100600
sif /perm/private.txt uid 4242
sif /perm/private.txt gid 4242
sif /perm/group.txt uid 4242
sif /perm/group.txt gid 4242
sif /perm/world.txt uid 4242
sif /perm/world.txt gid 4242
sif /perm/locked uid 4242
sif /perm/locked gid 4242
sif /perm/listonly uid 4242
sif /perm/listonly gid 4242
DBG
# ext4 with 4 KiB blocks and no journal.
truncate -s 4M "$OUT/ext4_4k.img"
mke2fs -q -t ext4 -O ^has_journal -b 4096 -N 1024 -L MOQI4K -d "$WORK/src" "$OUT/ext4_4k.img"
# ext3: block-mapped files (direct + indirect + double indirect), no extents.
truncate -s 4M "$OUT/ext3_1k.img"
mke2fs -q -t ext3 -b 1024 -N 1024 -L MOQIEXT3 -d "$WORK/src" "$OUT/ext3_1k.img"

# NTFS: 512-byte sectors, 1 KiB clusters. ntfscp cannot create directories, so
# the root holds the files; 120 long names push the root index into
# $INDEX_ALLOCATION blocks. Big/sparse files are non-resident.
truncate -s 4M "$OUT/ntfs.img"
mkntfs -q -F -f -s 512 -c 1024 -L MOQINTFS "$OUT/ntfs.img" >/dev/null 2>&1
ntfscp -f -q "$OUT/ntfs.img" "$WORK/src/small.txt" small.txt
ntfscp -f -q "$OUT/ntfs.img" "$WORK/src/big.bin" big.bin
ntfscp -f -q "$OUT/ntfs.img" "$WORK/src/sparse.bin" sparse.bin
ntfscp -f -q "$OUT/ntfs.img" "$WORK/src/empty.txt" empty.txt
for i in $(seq 1 120); do
    printf '%s\n' "$i" > "$WORK/f.txt"
    ntfscp -f -q "$OUT/ntfs.img" "$WORK/f.txt" "file_with_a_long_name_number_$i.txt"
done

# MBR-partitioned data disk for the QEMU smoke (attached as the 2nd virtio
# disk, "vblk1"): p1 = ext4 (type 83), p2 = NTFS (type 7).
truncate -s 10M "$OUT/datadisk.img"
sfdisk -q "$OUT/datadisk.img" <<'PT'
label: dos
unit: sectors
start=2048, size=8192, type=83
start=10240, size=8192, type=7
PT
dd if="$OUT/ext4_1k.img" of="$OUT/datadisk.img" bs=512 seek=2048 conv=notrunc status=none
dd if="$OUT/ntfs.img" of="$OUT/datadisk.img" bs=512 seek=10240 conv=notrunc status=none

# Same layout behind a GPT (protective MBR + header + 128 entries + backup).
truncate -s 10M "$OUT/datadisk_gpt.img"
sfdisk -q "$OUT/datadisk_gpt.img" <<'PT'
label: gpt
unit: sectors
start=2048, size=8192, type=0FC63DAF-8483-4772-8E79-3D69D8478480
start=10240, size=8192, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
PT
dd if="$OUT/ext4_1k.img" of="$OUT/datadisk_gpt.img" bs=512 seek=2048 conv=notrunc status=none
dd if="$OUT/ntfs.img" of="$OUT/datadisk_gpt.img" bs=512 seek=10240 conv=notrunc status=none
echo "wrote $OUT/{ext4_1k,ext4_4k,ext3_1k,ntfs,datadisk,datadisk_gpt}.img"
