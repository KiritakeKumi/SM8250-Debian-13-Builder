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

# ---------------------------------------------------------------------------
# 1b. Detect the kernel's major version.
#
# config/kernel-base.config was dumped from a working 6.18.35 board, so it
# carries some 6.18-only symbols. `olddefconfig` silently drops anything the
# target kernel no longer has, which is what we want -- but we must then verify
# the options that actually matter survived. The lists differ per major version
# because a few symbols were renamed (e.g. QCOM_Q6V5_COMMON) or moved.
# ---------------------------------------------------------------------------
KMAJOR="${KERNEL_VERSION%%.*}"          # 6 or 7
echo "kernel major version: $KMAJOR"

# Fail loudly if a required option is missing.
check_config() {
    local opt="$1" want="$2"
    local got
    got="$(grep -E "^${opt}=" "$KDIR/.config" || true)"
    if [[ "$got" != "${opt}=${want}" ]]; then
        echo "ERROR: kernel config $opt should be $want, got '${got:-<unset>}'" >&2
        echo "       (kernel $KERNEL_VERSION; see config/kernel-fragment.config)" >&2
        exit 1
    fi
}

# Portable across 6.x and 7.x: these exist in both.
check_config CONFIG_ARM64 y
check_config CONFIG_ARCH_QCOM y
check_config CONFIG_PCIE_QCOM y
check_config CONFIG_SCSI_UFS_QCOM y
check_config CONFIG_EXT4_FS y
check_config CONFIG_DEVTMPFS y
check_config CONFIG_BLK_DEV_INITRD y
check_config CONFIG_MODULES y
check_config CONFIG_ARM_SMMU y
check_config CONFIG_PHY_QCOM_QMP_PCIE y
check_config CONFIG_R8169 m

# 7.x-specific sanity: the out-of-tree helper module needs this API, and it is
# also the one that changed shape between 6.18 and 7.x.
if [[ "$KMAJOR" -ge 7 ]]; then
    echo "  (7.x: verifying the driver_override API the helper module uses)"
    if ! grep -q 'device_has_driver_override' "$KSRC/include/linux/device.h"; then
        echo "ERROR: this 7.x tree lacks device_has_driver_override()" >&2
        exit 1
    fi
fi

echo "---- kernel release ----"
make -C "$KSRC" O="$KDIR" ARCH=arm64 -s kernelrelease | tee "$ART/kernelrelease.txt"

# Guard against silently building a different kernel than requested: the
# release string feeds the module vermagic and the artifact names.
#
# Compare against $KERNEL_MAKEVERSION from the shared resolver, not against
# $KERNEL_VERSION: `make kernelrelease` prints three components, so a tree at
# tag v7.2 (SUBLEVEL = 0) says "7.2.0" and a literal comparison would reject
# the correct tree. The trailing-'+' form is still accepted -- setlocalversion
# appends it when the checkout is not exactly at a tag.
eval "$(bash "$REPO_ROOT/scripts/resolve-kernel-ref.sh" "$KERNEL_VERSION" --format=env)"
KREL_CHECK="$(cat "$ART/kernelrelease.txt")"
if [[ "$KREL_CHECK" != "$KERNEL_MAKEVERSION" && "$KREL_CHECK" != "$KERNEL_MAKEVERSION"+* ]]; then
    echo "ERROR: kernelrelease is '$KREL_CHECK' but KERNEL_VERSION is '$KERNEL_VERSION'" >&2
    echo "       (expected kernelrelease '$KERNEL_MAKEVERSION')." >&2
    echo "       The source tree is the wrong version. Delete work/src/linux-$KERNEL_VERSION" >&2
    echo "       and the matching CI cache, then rerun." >&2
    exit 1
fi
echo "release string OK: $KREL_CHECK"

# ---------------------------------------------------------------------------
# 2. Build
# ---------------------------------------------------------------------------
# NOTE: we deliberately do NOT pass the `dtbs` target. It would build every
# board DTB under arch/arm64/boot/dts/qcom/ (~200 of them, including apq8016,
# ipq8074, ...), which is slow and pollutes the log with unrelated warnings.
# Our board DTB is compiled separately in step 3, straight from $WORKSPACE/dts.
#
# `modules` IS required: step 4 runs `modules_install`, which needs the
# modules.order file that only the `modules` target produces. Building just
# Image.gz leads to:
#     No rule to make target 'modules.order', needed by '.../modules.order'
JOBS="$(nproc)"
echo "building kernel with -j$JOBS"
make -C "$KSRC" O="$KDIR" ARCH=arm64 -j"$JOBS" Image.gz modules \
    2>&1 | tee "$LOGDIR/kernel-build.log"

test -s "$KDIR/arch/arm64/boot/Image.gz" || { echo "Image.gz not built" >&2; exit 1; }
test -s "$KDIR/modules.order" || { echo "modules.order not produced" >&2; exit 1; }
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
# Ask this dtc which check names it knows: an unknown -Wno-<check> is FATAL,
# and the dtc bundled with Linux 7.2 dropped graph_child_address.
DTC_WFLAGS="$(sh "$REPO_ROOT/scripts/dtc-warn-flags.sh" "$KDIR/scripts/dtc/dtc")"
echo "  dtc warning flags: ${DTC_WFLAGS:-(none)}"
# shellcheck disable=SC2086  # DTC_WFLAGS must word-split into separate flags
"$KDIR/scripts/dtc/dtc" -o "$ART/$DTB_BASENAME.dtb" -b 0 \
    -i "$KSRC/arch/arm64/boot/dts/qcom" \
    -i "$KSRC/scripts/dtc/include-prefixes" \
    $DTC_WFLAGS \
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
    # Every external command /init uses must be listed here. `busybox
    # --install -s` on line 2 of /init is best-effort: it only links applets
    # that are actually compiled into this busybox, and it is allowed to fail
    # outright. scripts/validate.sh checks this list against /init.
    for applet in sh mount umount switch_root sleep echo cat ls mkdir mknod \
                  dmesg sed grep; do
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

# Honour rw/ro from the command line (config/boot-cmdline.txt asks for rw).
# Default to ro, like a stock initramfs: systemd remounts / per /etc/fstab.
RWFLAG=ro
for w in $(cat /proc/cmdline); do
    [ "$w" = "rw" ] && RWFLAG=rw
    [ "$w" = "ro" ] && RWFLAG=ro
done

mounted=0
tries=0
while [ $tries -lt 30 ]; do
    if mount -o "$RWFLAG" "$ROOT" /mnt/root 2>/dev/null; then
        mounted=1
        echo "[initramfs] mounted $ROOT $RWFLAG"
        break
    fi
    tries=$((tries+1))
    sleep 1
done

# NOTE: the result is judged by mount's own exit status and by shell builtins
# only -- never by an external helper. This check used to be
#     if ! mountpoint -q /mnt/root; then
# and the busybox that Debian/Ubuntu ships has no `mountpoint` applet, so it
# died with "/init: line 22: mountpoint: not found". `!` turned that 127 into
# "the mount failed", and a perfectly good rootfs was thrown away:
#     EXT4-fs (sda1): mounted filesystem ... ro with ordered data mode
#     [initramfs] mounted UUID=618ef20f-...
#     [initramfs] FAILED to mount UUID=618ef20f-..., dropping to shell
if [ "$mounted" != 1 ]; then
    echo "[initramfs] FAILED to mount $ROOT after ${tries}s, dropping to shell"
    echo "[initramfs] ---- /proc/mounts ----"; cat /proc/mounts 2>/dev/null
    echo "[initramfs] ---- /dev ----";         ls /dev 2>/dev/null
    exec /bin/sh
fi

# Sanity check with builtins only: did we mount something that looks like the
# Debian rootfs? NOTE: do NOT use `[ -x /mnt/root/sbin/init ]`. Debian's
# /sbin/init is an *absolute* symlink (-> /lib/systemd/systemd), and -x
# follows it relative to the current root -- the initramfs -- where that path
# does not exist. It would fail on a perfectly good rootfs. /etc is a real
# directory, and -L matches the link itself without dereferencing it.
rootfs_ok=1
[ -d /mnt/root/etc ] || rootfs_ok=0
[ -e /mnt/root/sbin/init ] || [ -L /mnt/root/sbin/init ] || rootfs_ok=0
if [ "$rootfs_ok" != 1 ]; then
    echo "[initramfs] $ROOT does not look like the Debian rootfs, dropping to shell"
    ls /mnt/root 2>/dev/null
    exec /bin/sh
fi

echo "[initramfs] switch_root -> /sbin/init"
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
