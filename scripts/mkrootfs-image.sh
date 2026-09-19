#!/usr/bin/env bash
# Pack $WORKSPACE/rootfs into a bare ext4 image (no partition table), sized to
# be written directly onto the board's UFS "rootfs" partition.
#
# Inputs:  WORKSPACE, ROOTFS_SIZE_MB, RELEASE_NAME
# Output:  $WORKSPACE/out/<IMAGE_NAME>-<release>.rootfs.img
set -euo pipefail

: "${WORKSPACE:?WORKSPACE not set}"
: "${ROOTFS_SIZE_MB:=6000}"
: "${RELEASE_NAME:=trixie}"

OUTDIR="${OUTDIR:-$WORKSPACE/out}"
ROOTFS="$WORKSPACE/rootfs"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/config/image.conf"

LOGDIR="$WORKSPACE/logs"
mkdir -p "$OUTDIR" "$LOGDIR"

IMG="$OUTDIR/${IMAGE_NAME}-${RELEASE_NAME}.rootfs.img"

USED_MB="$(du -sm "$ROOTFS" | cut -f1)"
if (( USED_MB + 300 > ROOTFS_SIZE_MB )); then
    echo "ERROR: rootfs uses ${USED_MB} MiB but image size is only ${ROOTFS_SIZE_MB} MiB" >&2
    exit 1
fi

echo "creating ${ROOTFS_SIZE_MB} MiB ext4 image at $IMG"
rm -f "$IMG"
truncate -s "${ROOTFS_SIZE_MB}M" "$IMG"
mkfs.ext4 -F -L rootfs -E lazy_itable_init=0,lazy_journal_init=0 "$IMG" \
    2>&1 | tee "$LOGDIR/mkfs-rootfs.log"

MNT="$(mktemp -d)"
mount -o loop "$IMG" "$MNT"
trap 'umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT

echo "copying rootfs (preserving xattrs/perms)"
tar -C "$ROOTFS" -cf - . | tar -C "$MNT" -xpf -

# Make sure the boot artifacts really landed.
for f in boot/Image.gz boot/initramfs.cpio.gz; do
    test -s "$MNT/$f" || { echo "ERROR: $f missing from image" >&2; exit 1; }
done

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

# shrink to the minimum, then report
e2fsck -p -f "$IMG" 2>&1 | tee -a "$LOGDIR/mkfs-rootfs.log" || true

ROOTFS_UUID="$(blkid -s UUID -o value "$IMG")"
echo "$ROOTFS_UUID" > "$WORKSPACE/rootfs-uuid.txt"
echo "rootfs UUID: $ROOTFS_UUID"

echo "rootfs image:"
ls -lh "$IMG"
