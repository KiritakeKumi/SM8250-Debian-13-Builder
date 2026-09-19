#!/usr/bin/env bash
# Build the rootfs with debootstrap (Debian 13 "trixie", arm64).
#
# Inputs (env):
#   WORKSPACE, KERNEL_VERSION, WITH_NIC_FIX
#   TARGET_HOSTNAME, TARGET_ROOT_PASSWORD, TARGET_ENABLE_SSH,
#   TARGET_EXTRA_PACKAGES, TARGET_MAKE_USER
#   DEBIAN_SUITE, DEBIAN_MIRROR, DEBIAN_SECURITY_MIRROR
#
# Output: $WORKSPACE/rootfs  (a complete arm64 root filesystem tree)
set -euo pipefail

: "${WORKSPACE:?WORKSPACE not set}"
: "${KERNEL_VERSION:?KERNEL_VERSION not set}"
: "${DEBIAN_SUITE:=trixie}"
: "${DEBIAN_MIRROR:=http://deb.debian.org/debian}"
: "${DEBIAN_SECURITY_MIRROR:=http://security.debian.org/debian-security}"
: "${TARGET_HOSTNAME:=nico-sm8250}"
: "${TARGET_ROOT_PASSWORD:=root}"
: "${TARGET_ENABLE_SSH:=true}"
: "${TARGET_EXTRA_PACKAGES:=}"
: "${TARGET_MAKE_USER:=true}"
: "${WITH_NIC_FIX:=false}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="$WORKSPACE/rootfs"
ART="$WORKSPACE/artifacts"
LOGDIR="$WORKSPACE/logs"
DTS_NAME="$(cat "$WORKSPACE/dts-name.txt")"
DTB_BASENAME="${DTS_NAME%.dts}"
KREL="$(cat "$ART/kernelrelease.txt")"

# shellcheck source=/dev/null
source "$REPO_ROOT/config/image.conf"

# ---------------------------------------------------------------------------
# debootstrap / chroot / mount all need root.
#
# In CI the runner user has passwordless sudo. Re-exec ourselves as root and
# explicitly carry the configuration across: sudo's env_reset would otherwise
# drop the variables this script is driven by. `sudo env VAR=...` is used
# rather than `sudo VAR=...` because the latter is not portable.
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "re-executing with sudo (debootstrap/chroot need root)"
        exec sudo env \
            WORKSPACE="$WORKSPACE" \
            KERNEL_VERSION="$KERNEL_VERSION" \
            WITH_NIC_FIX="$WITH_NIC_FIX" \
            OUTDIR="${OUTDIR:-}" \
            RELEASE_NAME="$RELEASE_NAME" \
            DEBIAN_SUITE="$DEBIAN_SUITE" \
            DEBIAN_MIRROR="$DEBIAN_MIRROR" \
            DEBIAN_SECURITY_MIRROR="$DEBIAN_SECURITY_MIRROR" \
            TARGET_HOSTNAME="$TARGET_HOSTNAME" \
            TARGET_ROOT_PASSWORD="$TARGET_ROOT_PASSWORD" \
            TARGET_ENABLE_SSH="$TARGET_ENABLE_SSH" \
            TARGET_EXTRA_PACKAGES="$TARGET_EXTRA_PACKAGES" \
            TARGET_MAKE_USER="$TARGET_MAKE_USER" \
            bash "$(readlink -f "$0")" "$@"
    fi
    echo "ERROR: this script must run as root (debootstrap, chroot, mount)." >&2
    echo "       Re-run with sudo." >&2
    exit 1
fi

# debootstrap/chroot only works natively. The CI runner is ubuntu-24.04-arm,
# so this should always be arm64. On x86 you would need qemu-user-static +
# binfmt and to pass --foreign, which this script deliberately does not do.
HOST_ARCH="$(dpkg --print-architecture)"
if [[ "$HOST_ARCH" != "arm64" ]]; then
    echo "ERROR: this script must run on an arm64 host (got $HOST_ARCH)." >&2
    echo "       Use the ubuntu-24.04-arm CI runner, or an arm64 machine/WSL2." >&2
    exit 1
fi

mkdir -p "$LOGDIR"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

# ---------------------------------------------------------------------------
# 1. debootstrap
# ---------------------------------------------------------------------------
# The build host is arm64 (GitHub Actions ubuntu-24.04-arm), so debootstrap
# runs natively: no --foreign, no qemu-user-static, no binfmt.
echo "debootstrap $DEBIAN_SUITE -> $ROOTFS"
debootstrap --arch=arm64 --variant=minbase \
    --components=main,contrib,non-free-firmware \
    "$DEBIAN_SUITE" "$ROOTFS" "$DEBIAN_MIRROR" \
    2>&1 | tee "$LOGDIR/debootstrap.log"

# A native debootstrap can still leave the tree half-configured if a package
# fails; make sure the second stage really ran.
if [[ -x "$ROOTFS/debootstrap/debootstrap" ]]; then
    echo "running debootstrap second stage"
    chroot "$ROOTFS" /debootstrap/debootstrap --second-stage 2>&1 | tee -a "$LOGDIR/debootstrap.log"
fi

# ---------------------------------------------------------------------------
# 2. sources.list + base packages
# ---------------------------------------------------------------------------
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_SUITE main contrib non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates main contrib non-free-firmware
deb $DEBIAN_SECURITY_MIRROR $DEBIAN_SUITE-security main contrib non-free-firmware
EOF

# do not start daemons during install inside the chroot
cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

mount_chroot() {
    mount -t proc  none "$ROOTFS/proc" 2>/dev/null || true
    mount -t sysfs none "$ROOTFS/sys"  2>/dev/null || true
    mount --bind /dev "$ROOTFS/dev"    2>/dev/null || true
    mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null || true
}
umount_chroot() {
    umount -lf "$ROOTFS/dev/pts" 2>/dev/null || true
    umount -lf "$ROOTFS/dev"     2>/dev/null || true
    umount -lf "$ROOTFS/sys"     2>/dev/null || true
    umount -lf "$ROOTFS/proc"    2>/dev/null || true
}
trap umount_chroot EXIT
mount_chroot

PKGS=(
    systemd systemd-sysv udev kmod
    initramfs-tools
    linux-base
    apt-utils ca-certificates locales tzdata
    net-tools iproute2 iputils-ping
    ethtool
    openssh-server
    sudo less nano vim-tiny
    zstd xz-utils gdisk parted e2fsprogs dosfstools
    rfkill wireless-regdb
    usbutils pciutils
    bash-completion
    dbus
)

# --- firmware -------------------------------------------------------------
# The board needs two firmware families:
#   firmware-realtek : rtl_nic/rtl8168h-2.fw for the two RTL8168 NICs on PCIe1.
#                      Without it r8169 falls back to a degraded configuration.
#   firmware-qcom-soc: QCA6390 (wifi/BT), a650 GPU, adsp/cdsp, etc.
# firmware-linux-free is pulled in by the base set above.
PKGS+=(
    firmware-realtek
    firmware-qcom-soc
    firmware-linux-nonfree
)

if [[ -n "$TARGET_EXTRA_PACKAGES" ]]; then
    # shellcheck disable=SC2206
    PKGS+=( $TARGET_EXTRA_PACKAGES )
fi
if [[ -s "$REPO_ROOT/config/packages.txt" ]]; then
    while read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        PKGS+=( "$line" )
    done < "$REPO_ROOT/config/packages.txt"
fi

# De-duplicate while keeping order.
mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | awk '!seen[$0]++')

echo "installing packages: ${PKGS[*]}"
chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get update 2>&1 | tee -a "$LOGDIR/rootfs-apt.log"
chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends "${PKGS[@]}" \
    2>&1 | tee -a "$LOGDIR/rootfs-apt.log"

# ---------------------------------------------------------------------------
# 3. Kernel + DTB + modules into the rootfs
# ---------------------------------------------------------------------------
install -d "$ROOTFS/boot" "$ROOTFS/lib/modules/$KREL" "$ROOTFS/usr/lib/firmware"

cp -v "$ART/Image.gz"                "$ROOTFS/boot/Image.gz"
cp -v "$ART/$DTB_BASENAME.dtb"       "$ROOTFS/boot/$DTB_BASENAME.dtb"
cp -v "$ART/initramfs.cpio.gz"       "$ROOTFS/boot/initramfs.cpio.gz"

if [[ -d "$WORKSPACE/modules-stage/lib/modules" ]]; then
    cp -a "$WORKSPACE/modules-stage/lib/modules/." "$ROOTFS/lib/modules/"
fi
if [[ -d "$ART/modules" ]] && compgen -G "$ART/modules/*.ko" > /dev/null; then
    install -d "$ROOTFS/lib/modules/$KREL/extra"
    cp -v "$ART/modules/"*.ko "$ROOTFS/lib/modules/$KREL/extra/"
fi

# module metadata
chroot "$ROOTFS" /sbin/depmod -a "$KREL" 2>&1 | tee -a "$LOGDIR/rootfs-depmod.log" || true

# ---------------------------------------------------------------------------
# 3b. Verify the firmware the board actually needs is present
# ---------------------------------------------------------------------------
# Debian 13 moved firmware to /usr/lib/firmware, but the kernel looks in
# /lib/firmware too. Make sure both paths resolve.
if [[ -d "$ROOTFS/usr/lib/firmware" && ! -e "$ROOTFS/lib/firmware" ]]; then
    ln -sfn usr/lib/firmware "$ROOTFS/lib/firmware"
fi

fw_check() {
    local rel="$1" why="$2"
    if compgen -G "$ROOTFS/usr/lib/firmware/$rel" > /dev/null 2>&1 \
       || compgen -G "$ROOTFS/lib/firmware/$rel" > /dev/null 2>&1; then
        echo "  OK   $rel   ($why)"
    else
        echo "  MISS $rel   ($why)"
        FW_FAIL=1
    fi
}
FW_FAIL=0
echo "---- firmware check ----"
fw_check 'rtl_nic/rtl8168h-2.fw'  'RTL8168 NICs on PCIe1'
fw_check 'rtl_nic/rtl8168g-2.fw'  'RTL8168 fallback'
fw_check 'qcom/a650_sqe.fw'       'Adreno A650'
fw_check 'qcom/a650_gmu.bin'      'Adreno A650 GMU'
fw_check 'qcom/sm8250/*'          'ADSP/CDSP/modem firmware'
if (( FW_FAIL )); then
    echo "ERROR: required firmware missing from the rootfs" >&2
    echo "       check that non-free-firmware is enabled in sources.list" >&2
    exit 1
fi
echo "all required firmware present"

# ---------------------------------------------------------------------------
# 4. Hostname / hosts / fstab / locale / timezone
# ---------------------------------------------------------------------------
echo "$TARGET_HOSTNAME" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1       localhost
127.0.1.1       $TARGET_HOSTNAME
::1             localhost ip6-localhost ip6-loopback
EOF

# rootfs is a single ext4 partition written to the UFS "rootfs" partition.
# root=UUID=... is passed on the kernel command line, so / is enough here.
cat > "$ROOTFS/etc/fstab" <<'EOF'
# <file system>  <mount point>  <type>  <options>          <dump>  <pass>
/dev/root        /              ext4    errors=remount-ro  0       1
proc             /proc          proc    defaults           0       0
sysfs            /sys           sysfs   defaults           0       0
devtmpfs         /dev           devtmpfs defaults          0       0
tmpfs            /tmp           tmpfs   defaults,size=512M 0       0
EOF

echo "en_US.UTF-8 UTF-8" > "$ROOTFS/etc/locale.gen"
chroot "$ROOTFS" /usr/sbin/locale-gen 2>&1 | tee -a "$LOGDIR/rootfs-misc.log" || true
echo 'LANG=en_US.UTF-8' > "$ROOTFS/etc/default/locale"

ln -sf /usr/share/zoneinfo/Asia/Shanghai "$ROOTFS/etc/localtime"
echo "Asia/Shanghai" > "$ROOTFS/etc/timezone"

# ---------------------------------------------------------------------------
# 5. Users
# ---------------------------------------------------------------------------
# root keeps TARGET_ROOT_PASSWORD (default "root").
# The normal user is "debian" with password "debian" (Debian's conventional
# installer defaults), and gets sudo.
echo "root:$TARGET_ROOT_PASSWORD" | chroot "$ROOTFS" chpasswd

if [[ "$TARGET_MAKE_USER" == "true" ]]; then
    if ! chroot "$ROOTFS" id -u debian >/dev/null 2>&1; then
        chroot "$ROOTFS" useradd -m -s /bin/bash -G sudo,audio,video,plugdev debian
    fi
    echo "debian:debian" | chroot "$ROOTFS" chpasswd
    install -d -m 0755 "$ROOTFS/etc/sudoers.d"
    echo 'debian ALL=(ALL:ALL) NOPASSWD:ALL' > "$ROOTFS/etc/sudoers.d/010-debian"
    chmod 0440 "$ROOTFS/etc/sudoers.d/010-debian"
fi

# ---------------------------------------------------------------------------
# 6. Serial console on ttyMSM0
# ---------------------------------------------------------------------------
mkdir -p "$ROOTFS/etc/systemd/system/serial-getty@ttyMSM0.service.d"
cat > "$ROOTFS/etc/systemd/system/serial-getty@ttyMSM0.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\u' --keep-baud 115200,38400,9600 %I $TERM
EOF
chroot "$ROOTFS" systemctl enable serial-getty@ttyMSM0.service 2>&1 | tee -a "$LOGDIR/rootfs-misc.log" || true

# ---------------------------------------------------------------------------
# 7. Networking
# ---------------------------------------------------------------------------
if [[ "$TARGET_ENABLE_SSH" == "true" ]]; then
    chroot "$ROOTFS" systemctl enable ssh 2>&1 | tee -a "$LOGDIR/rootfs-misc.log" || true
fi

# DHCP on the two wired ports. The interfaces may not exist at first boot
# (PCIe1 comes up late), so mark them optional.
install -d -m 0755 "$ROOTFS/etc/systemd/network"
for iface in eth0 eth1; do
cat > "$ROOTFS/etc/systemd/network/20-$iface.network" <<EOF
[Match]
Name=$iface

[Network]
DHCP=ipv4
IPv6AcceptRA=yes

[DHCPv4]
UseDomains=yes
EOF
done
chroot "$ROOTFS" systemctl enable systemd-networkd 2>&1 | tee -a "$LOGDIR/rootfs-misc.log" || true
chroot "$ROOTFS" systemctl enable systemd-resolved 2>&1 | tee -a "$LOGDIR/rootfs-misc.log" || true
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"

# ---------------------------------------------------------------------------
# 8. Out-of-tree helper modules: load them early
# ---------------------------------------------------------------------------
if [[ "$WITH_NIC_FIX" == "true" ]]; then
    install -d -m 0755 "$ROOTFS/etc/systemd/system/sysinit.target.wants"
    cat > "$ROOTFS/etc/systemd/system/tc-eb5-oot.service" <<EOF
[Unit]
Description=nico-debian-sm8250 PCIe1 board helper modules
DefaultDependencies=no
After=local-fs.target systemd-udevd.service
Before=sysinit.target

[Service]
Type=oneshot
TimeoutStartSec=60s
ExecStart=/usr/sbin/modprobe tc-eb5-pcie-helper
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
    chroot "$ROOTFS" systemctl enable tc-eb5-oot.service 2>&1 | tee -a "$LOGDIR/rootfs-misc.log" || true
fi

# ---------------------------------------------------------------------------
# 9. Cleanup
# ---------------------------------------------------------------------------
rm -f "$ROOTFS/usr/sbin/policy-rc.d"
chroot "$ROOTFS" apt-get clean 2>/dev/null || true
rm -rf "$ROOTFS/var/lib/apt/lists/"*
rm -rf "$ROOTFS/var/cache/apt/archives/"*.deb
umount_chroot
trap - EXIT

echo "rootfs ready at $ROOTFS ($(du -sh "$ROOTFS" | cut -f1))"
