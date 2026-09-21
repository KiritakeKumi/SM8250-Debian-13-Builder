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

# ---------------------------------------------------------------------------
# Loop-mounting the image needs root. Re-exec with sudo, carrying the config
# across (sudo's env_reset would drop it otherwise).
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "re-executing with sudo (loop mount needs root)"
        exec sudo env \
            WORKSPACE="$WORKSPACE" \
            ROOTFS_SIZE_MB="$ROOTFS_SIZE_MB" \
            RELEASE_NAME="$RELEASE_NAME" \
            OUTDIR="${OUTDIR:-}" \
            bash "$(readlink -f "$0")" "$@"
    fi
    echo "ERROR: this script must run as root (loop mount)." >&2
    echo "       Re-run with sudo." >&2
    exit 1
fi

LOGDIR="$WORKSPACE/logs"
mkdir -p "$OUTDIR" "$LOGDIR"

IMG="$OUTDIR/${IMAGE_NAME}-${RELEASE_NAME}.rootfs.img"

USED_MB="$(du -sm "$ROOTFS" | cut -f1)"
if (( USED_MB + 300 > ROOTFS_SIZE_MB )); then
    echo "ERROR: rootfs uses ${USED_MB} MiB but image size is only ${ROOTFS_SIZE_MB} MiB" >&2
    echo "       Raise rootfs_size_mb, or trim packages.txt." >&2
    exit 1
fi

# Check free space before creating the image.
#
# The image is created with truncate (sparse), so it does not consume
# ROOTFS_SIZE_MB up front -- but writing the actual rootfs into it does consume
# roughly USED_MB. Also budget for the final artifact upload/compression.
NEED_MB=$(( USED_MB + 1024 ))
AVAIL_MB=$(( $(df -Pk "$OUTDIR" | awk 'NR==2 {print $4}') / 1024 ))
echo "rootfs tree: ${USED_MB} MiB   image size: ${ROOTFS_SIZE_MB} MiB   free here: ${AVAIL_MB} MiB"
if (( AVAIL_MB < NEED_MB )); then
    echo "ERROR: need about ${NEED_MB} MiB free in $OUTDIR but only ${AVAIL_MB} MiB is available." >&2
    echo "       Lower rootfs_size_mb, or free space (see scripts/free-disk-space.sh)." >&2
    exit 1
fi

echo "creating ${ROOTFS_SIZE_MB} MiB ext4 image at $IMG"
rm -f "$IMG"
truncate -s "${ROOTFS_SIZE_MB}M" "$IMG"
# -U: pin the UUID. Without it mkfs.ext4 rolls a random one per build, and
# build-bootimg.sh bakes it into root=UUID=... -- so a boot.img could only ever
# boot the rootfs.img built alongside it. See config/image.conf.
mkfs.ext4 -F -L rootfs -U "$ROOTFS_UUID" \
    -E lazy_itable_init=0,lazy_journal_init=0 "$IMG" \
    2>&1 | tee "$LOGDIR/mkfs-rootfs.log"

MNT="$(mktemp -d)"
mount -o loop "$IMG" "$MNT"
trap 'umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT

echo "copying rootfs (preserving xattrs/caps/perms)"
# --xattrs is REQUIRED on BOTH ends. Without it GNU tar silently drops the
# security.* extended attributes, and the file capabilities go with them:
#   /usr/bin/ping loses cap_net_raw+ep, so an unprivileged `ping` fails with
#     ping: socktype: SOCK_RAW
#     ping: socket: Operation not permitted (missing cap_net_raw+p capability)
# while root still works (root bypasses the capability check). The
# --xattrs-include='*' is needed because tar restricts to user.* by default;
# security.capability lives in the security.* namespace.
tar --xattrs --xattrs-include='*' -C "$ROOTFS" -cf - . \
    | tar --xattrs --xattrs-include='*' -C "$MNT" -xpf -

# Belt-and-braces: confirm the capability actually survived the round trip, so
# this can never silently regress again. getcap may be absent on the runner;
# fall back to reading the raw xattr.
if [[ -e "$MNT/usr/bin/ping" ]]; then
    caps=""
    if command -v getcap >/dev/null 2>&1; then
        caps="$(getcap "$MNT/usr/bin/ping" 2>/dev/null || true)"
    elif command -v getfattr >/dev/null 2>&1; then
        caps="$(getfattr -n security.capability --only-values "$MNT/usr/bin/ping" 2>/dev/null || true)"
    fi
    if [[ -n "$caps" ]]; then
        echo "  cap check: /usr/bin/ping carries capabilities ($caps)"
    else
        echo "WARNING: /usr/bin/ping has no file capabilities in the image;" >&2
        echo "         unprivileged ping will fail. Is tar --xattrs working?" >&2
    fi
fi

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

ROOTFS_UUID_ACTUAL="$(blkid -s UUID -o value "$IMG")"
if [[ "$ROOTFS_UUID_ACTUAL" != "$ROOTFS_UUID" ]]; then
    echo "ERROR: image UUID is '$ROOTFS_UUID_ACTUAL' but config/image.conf pins" >&2
    echo "       '$ROOTFS_UUID'. The kernel command line would not match the" >&2
    echo "       filesystem and the initramfs could not find the rootfs." >&2
    exit 1
fi
echo "$ROOTFS_UUID_ACTUAL" > "$WORKSPACE/rootfs-uuid.txt"
echo "rootfs UUID: $ROOTFS_UUID_ACTUAL (pinned in config/image.conf)"

echo "rootfs image:"
ls -lh "$IMG"
