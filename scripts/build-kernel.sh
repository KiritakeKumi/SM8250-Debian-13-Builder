#!/usr/bin/env bash
# Build the kernel, the board DTB and a small initramfs.
#
# Inputs (env):
#   WORKSPACE       - scratch dir
#   KERNEL_VERSION  - e.g. 6.18.35
#   WITH_NIC_FIX    - true/false; controls a couple of config knobs
#
# Outputs (into $WORKSPACE/artifacts/):
#   Image.gz        - gzip-compressed arm64 kernel
#   <board>.dtb     - board device tree blob
#   initramfs.cpio.gz
set -euo pipefail

: "${WORKSPACE:?WORKSPACE not set}"
: "${KERNEL_VERSION:?KERNEL_VERSION not set}"
: "${WITH_NIC_FIX:=false}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KSRC="$WORKSPACE/src/linux-$KERNEL_VERSION"
KDIR="$WORKSPACE/build/linux"
ART="$WORKSPACE/artifacts"
LOGDIR="$WORKSPACE/logs"
DTS_NAME="$(cat "$WORKSPACE/dts-name.txt")"
DTB_BASENAME="${DTS_NAME%.dts}"

# shellcheck source=/dev/null
source "$REPO_ROOT/config/image.conf"

mkdir -p "$KDIR" "$ART" "$LOGDIR"

test -f "$KSRC/Makefile" || { echo "kernel source missing at $KSRC" >&2; exit 1; }

# The DTS preprocessor needs the full dt-bindings set. In particular
# include/dt-bindings/input/linux-event-codes.h is a symlink into include/uapi.
for h in include/dt-bindings/input/linux-event-codes.h \
         include/uapi/linux/input-event-codes.h \
         arch/arm64/boot/dts/qcom/sm8250.dtsi ; do
    [[ -e "$KSRC/$h" ]] || {
        echo "ERROR: kernel source is incomplete: $KSRC/$h is missing." >&2
        echo "       A full tarball has everything; a sparse checkout needs" >&2
        echo "       both include/dt-bindings and include/uapi." >&2
        exit 1
    }
done

# ---------------------------------------------------------------------------
# 1. Assemble .config
# ---------------------------------------------------------------------------
# Start from the base defconfig shipped in this repo (a mainline arm64
# defconfig with the SM8250 / UFS / PCIe / QMP pieces enabled), then apply the
# fragment on top. `make olddefconfig` resolves anything left over.
cp -v "$REPO_ROOT/config/kernel-base.config" "$KDIR/.config"

if [[ -s "$REPO_ROOT/config/kernel-fragment.config" ]]; then
    echo "applying kernel fragment"
    # merge_config.sh ships with the kernel tree
    "$KSRC/scripts/kconfig/merge_config.sh" -m -O "$KDIR" \
        "$KDIR/.config" "$REPO_ROOT/config/kernel-fragment.config" \
        2>&1 | tee "$LOGDIR/kernel-fragment.log"
fi

make -C "$KSRC" O="$KDIR" ARCH=arm64 olddefconfig 2>&1 | tee "$LOGDIR/kernel-olddefconfig.log"

# Fail loudly if a required option is missing.
check_config() {
    local opt="$1" want="$2"
    local got
    got="$(grep -E "^${opt}=" "$KDIR/.config" || true)"
    if [[ "$got" != "${opt}=${want}" ]]; then
        echo "ERROR: kernel config $opt should be $want, got '${got:-<unset>}'" >&2
        exit 1
    fi
}
check_config CONFIG_ARM64 y
check_config CONFIG_ARCH_QCOM y
check_config CONFIG_PCIE_QCOM y
check_config CONFIG_SCSI_UFS_QCOM y
check_config CONFIG_EXT4_FS y
check_config CONFIG_DEVTMPFS y
check_config CONFIG_BLK_DEV_INITRD y
check_config CONFIG_MODULES y

echo "---- kernel release ----"
make -C "$KSRC" O="$KDIR" ARCH=arm64 -s kernelrelease | tee "$ART/kernelrelease.txt"

# ---------------------------------------------------------------------------
# 2. Build
# ---------------------------------------------------------------------------
# NOTE: we deliberately do NOT pass the `dtbs` target. It would build every
# board DTB under arch/arm64/boot/dts/qcom/ (~200 of them, including apq8016,
# ipq8074, ...), which is slow and pollutes the log with unrelated warnings.
# Our board DTB is compiled separately in step 3, straight from $WORKSPACE/dts.
JOBS="$(nproc)"
echo "building kernel with -j$JOBS"
make -C "$KSRC" O="$KDIR" ARCH=arm64 -j"$JOBS" Image.gz 2>&1 | tee "$LOGDIR/kernel-build.log"

test -s "$KDIR/arch/arm64/boot/Image.gz" || { echo "Image.gz not built" >&2; exit 1; }
cp -v "$KDIR/arch/arm64/boot/Image.gz" "$ART/Image.gz"

# ---------------------------------------------------------------------------
# 3. Build the board DTB from $WORKSPACE/dts (not from the kernel tree)
# ---------------------------------------------------------------------------
# The board DT may be a mainline-style file that #includes sm8250.dtsi etc.
# Preprocess it the same way the kernel build does, then compile with dtc.
DTS_DIR="$WORKSPACE/dts"
DTB_SRC="$DTS_DIR/$DTS_NAME"

# When the NIC fix is enabled, append the board overlay that enables PCIe1 and
# adds the helper node the out-of-tree module binds to.
if [[ "$WITH_NIC_FIX" == "true" ]]; then
    echo "appending NIC fix overlay to $DTS_NAME"
    {
        cat "$DTB_SRC"
        echo
        cat "$REPO_ROOT/dts/patches/nic-fix-overlay.dtsi"
    } > "$DTS_DIR/$DTS_NAME.merged.dts"
    DTB_SRC="$DTS_DIR/$DTS_NAME.merged.dts"
fi

echo "preprocessing $DTS_NAME"
# -E is REQUIRED: without it gcc tries to *assemble* the DTS instead of just
# running the preprocessor, and you get a wall of
#   "Assembler messages: Error: unknown mnemonic `interrupt'"
# because the file is not assembly.
gcc -E -nostdinc \
    -I "$KSRC/scripts/dtc/include-prefixes" \
    -I "$KSRC/arch/arm64/boot/dts/qcom" \
    -I "$KSRC/arch/arm64/boot/dts" \
    -I "$KSRC/include" \
    -I "$DTS_DIR" \
    -undef -D__DTS__ -x assembler-with-cpp \
    -o "$ART/$DTB_BASENAME.preprocessed.dts" "$DTB_SRC"

test -s "$ART/$DTB_BASENAME.preprocessed.dts" || {
    echo "ERROR: DTS preprocessing produced nothing" >&2
    exit 1
}
# The preprocessed output must still look like a device tree.
if ! grep -q '^/dts-v1/;' "$ART/$DTB_BASENAME.preprocessed.dts"; then
    echo "ERROR: preprocessed DTS does not start with /dts-v1/;" >&2
    echo "       first 5 lines were:" >&2
    head -5 "$ART/$DTB_BASENAME.preprocessed.dts" >&2
    exit 1
fi
echo "  preprocessed: $(wc -l < "$ART/$DTB_BASENAME.preprocessed.dts") lines"

echo "compiling $DTB_BASENAME.dtb"
"$KDIR/scripts/dtc/dtc" -o "$ART/$DTB_BASENAME.dtb" -b 0 \
    -i "$KSRC/arch/arm64/boot/dts/qcom" \
    -i "$KSRC/scripts/dtc/include-prefixes" \
    -Wno-unique_unit_address -Wno-unit_address_vs_reg -Wno-avoid_unnecessary_addr_size \
    -Wno-alias_paths -Wno-graph_child_address -Wno-simple_bus_reg \
    "$ART/$DTB_BASENAME.preprocessed.dts" 2>&1 | tee "$LOGDIR/dtc.log"

test -s "$ART/$DTB_BASENAME.dtb" || { echo "DTB not built" >&2; exit 1; }
echo "DTB size: $(stat -c%s "$ART/$DTB_BASENAME.dtb") bytes"

# ---------------------------------------------------------------------------
# 4. Install kernel modules into a staging tree (picked up by the rootfs step)
# ---------------------------------------------------------------------------
MODSTAGE="$WORKSPACE/modules-stage"
rm -rf "$MODSTAGE"
mkdir -p "$MODSTAGE"
make -C "$KSRC" O="$KDIR" ARCH=arm64 INSTALL_MOD_PATH="$MODSTAGE" INSTALL_MOD_STRIP=1 \
    modules_install 2>&1 | tee "$LOGDIR/modules-install.log"

# ---------------------------------------------------------------------------
# 5. Tiny initramfs
# ---------------------------------------------------------------------------
# The board rootfs lives on UFS and is up before PCIe, so a minimal initramfs
# is enough: it just needs to mount the rootfs by UUID and switch_root.
build_initramfs() {
    local work="$WORKSPACE/initramfs"
    rm -rf "$work"
    mkdir -p "$work"/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin,lib,lib64,mnt/root}

    # static busybox from the host package
    local bb
    bb="$(command -v busybox || true)"
    if [[ -z "$bb" ]]; then
        echo "busybox not found on host; installing via apt is expected in CI" >&2
        return 1
    fi
    cp "$bb" "$work/bin/busybox"
    for applet in sh mount umount switch_root sleep echo cat ls mkdir mknod dmesg; do
        ln -sf busybox "$work/bin/$applet"
    done
    ln -sf ../bin/busybox "$work/sbin/init"

    cat > "$work/init" <<'INITEOF'
#!/bin/busybox sh
/bin/busybox --install -s /bin 2>/dev/null || true
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev 2>/dev/null || true

# root= is on the kernel command line; the generic mount helper below reads it.
ROOT="$(sed -n 's/.*\broot=\([^ ]*\).*/\1/p' /proc/cmdline)"
echo "[initramfs] root=$ROOT"
[ -z "$ROOT" ] && ROOT=/dev/sda1

tries=0
while [ $tries -lt 30 ]; do
    if mount -o ro "$ROOT" /mnt/root 2>/dev/null; then
        echo "[initramfs] mounted $ROOT"
        break
    fi
    tries=$((tries+1))
    sleep 1
done

if ! mountpoint -q /mnt/root; then
    echo "[initramfs] FAILED to mount $ROOT, dropping to shell"
    exec /bin/sh
fi

exec switch_root /mnt/root /sbin/init
INITEOF
    chmod +x "$work/init"

    ( cd "$work" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$ART/initramfs.cpio.gz" )
}
build_initramfs

test -s "$ART/initramfs.cpio.gz" || { echo "initramfs not built" >&2; exit 1; }
echo "initramfs size: $(stat -c%s "$ART/initramfs.cpio.gz") bytes"

echo "==== artifacts ===="
ls -lh "$ART"
