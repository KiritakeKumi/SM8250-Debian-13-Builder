#!/usr/bin/env bash
# Pack an Android boot image (header v0) exactly like the vendor/board one:
#
#   [4096B android header][gzip Image + appended DTB][gzip cpio initramfs]
#
# Matches the values observed on the board's own boot.img:
#   kernel_addr  0x8000
#   ramdisk_addr 0x1000000
#   tags_addr    0x100
#   second_offset 0x00f00000
#   page_size    4096
#
# Inputs:  WORKSPACE, OUTDIR, RELEASE_NAME, KERNEL_VERSION
# Output:  $OUTDIR/<IMAGE_NAME>-<release>.boot.img
#          $OUTDIR/<IMAGE_NAME>-<release>.boot-recovery.img
set -euo pipefail

: "${WORKSPACE:?WORKSPACE not set}"
: "${RELEASE_NAME:=trixie}"
: "${KERNEL_VERSION:=unknown}"

OUTDIR="${OUTDIR:-$WORKSPACE/out}"
ART="$WORKSPACE/artifacts"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/config/image.conf"

LOGDIR="$WORKSPACE/logs"
DTS_NAME="$(cat "$WORKSPACE/dts-name.txt")"
DTB_BASENAME="${DTS_NAME%.dts}"
mkdir -p "$OUTDIR" "$LOGDIR"

ROOTFS_UUID="$(cat "$WORKSPACE/rootfs-uuid.txt")"

# ---------------------------------------------------------------------------
# Build the kernel blob: gzip'd Image with the DTB appended (ABL convention)
# ---------------------------------------------------------------------------
KERNEL_BLOB="$WORKSPACE/kernel-with-dtb.gz"
cat "$ART/Image.gz" "$ART/$DTB_BASENAME.dtb" > "$KERNEL_BLOB"
echo "kernel+dtb blob: $(stat -c%s "$KERNEL_BLOB") bytes"

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------
CMDLINE_TEMPLATE="$REPO_ROOT/config/boot-cmdline.txt"
# Strip comment lines and blanks, substitute the real UUID, collapse spaces.
CMDLINE="$(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$CMDLINE_TEMPLATE" \
    | sed "s|@ROOTFS_UUID@|$ROOTFS_UUID|g" \
    | tr '\n' ' ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')"
echo "cmdline: $CMDLINE"
if (( ${#CMDLINE} > 511 )); then
    echo "ERROR: cmdline is ${#CMDLINE} chars; the board's bootloader only forwards ~511" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# mkbootimg
# ---------------------------------------------------------------------------
# Prefer the Debian/Ubuntu packaged tool; fall back to the pip one.
MKBOOTIMG=""
for cand in mkbootimg /usr/bin/mkbootimg; do
    if command -v "$cand" >/dev/null 2>&1; then MKBOOTIMG="$cand"; break; fi
done
if [[ -z "$MKBOOTIMG" ]]; then
    pip3 install --quiet --break-system-packages mkbootimg 2>/dev/null || \
        pip3 install --quiet mkbootimg
    MKBOOTIMG="$(command -v mkbootimg)"
fi
echo "using mkbootimg: $MKBOOTIMG"

mk_one() {
    local out="$1" ramdisk="$2"
    "$MKBOOTIMG" \
        --kernel         "$KERNEL_BLOB" \
        --ramdisk        "$ramdisk" \
        --base           0x0 \
        --second_offset  0x00f00000 \
        --cmdline        "$CMDLINE" \
        --kernel_offset  0x8000 \
        --ramdisk_offset 0x1000000 \
        --tags_offset    0x100 \
        --pagesize       4096 \
        -o "$out"
    echo "wrote $out ($(stat -c%s "$out") bytes)"
}

mk_one "$OUTDIR/${IMAGE_NAME}-${RELEASE_NAME}.boot.img"          "$ART/initramfs.cpio.gz"
mk_one "$OUTDIR/${IMAGE_NAME}-${RELEASE_NAME}.boot-recovery.img" "$ART/initramfs.cpio.gz"

# ---------------------------------------------------------------------------
# Verify the header looks like the board expects
# ---------------------------------------------------------------------------
verify_header() {
    local img="$1"
    python3 - "$img" <<'PYEOF'
import struct, sys
p = sys.argv[1]
with open(p, 'rb') as f:
    h = f.read(4096)
magic = h[:8].decode('ascii', 'replace')
ksize, kaddr = struct.unpack_from('<II', h, 8)
rsize, raddr = struct.unpack_from('<II', h, 16)
ssize, saddr = struct.unpack_from('<II', h, 24)
tags = struct.unpack_from('<I', h, 32)[0]
page = struct.unpack_from('<I', h, 36)[0]
hver = struct.unpack_from('<I', h, 40)[0]
cmd = h[64:64+512].split(b'\0')[0].decode('ascii', 'replace')
print(f'  magic={magic} header_version={hver} page_size={page}')
print(f'  kernel={ksize}@{kaddr:#x} ramdisk={rsize}@{raddr:#x} second={ssize}@{saddr:#x} tags={tags:#x}')
print(f'  cmdline={cmd}')
assert magic == 'ANDROID!', 'bad magic'
assert page == 4096, 'bad page size'
assert kaddr == 0x8000, 'bad kernel addr'
assert raddr == 0x1000000, 'bad ramdisk addr'
assert hver == 0, 'unexpected header version'
print('  header OK')
PYEOF
}
echo "---- boot.img header ----"
verify_header "$OUTDIR/${IMAGE_NAME}-${RELEASE_NAME}.boot.img"

ls -lh "$OUTDIR"
