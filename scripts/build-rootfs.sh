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
# 3c. Bake the GPU firmware into the initramfs
# ---------------------------------------------------------------------------
# CONFIG_DRM_MSM=y is built-in and probes during the initramfs stage, BEFORE
# /init runs switch_root -- so the Adreno microcode, which lives in the rootfs,
# is not reachable yet and the load fails on every boot:
#     msm_dpu ...: Direct firmware load for qcom/a650_sqe.fw failed error -2
#     [drm:adreno_request_fw] *ERROR* failed to load a650_sqe.fw
#     [drm] Cannot find any crtc or sizes
# The initramfs is unpacked in a rootfs_initcall, before device_initcall driver
# probes, so firmware placed in it IS present when the GPU probes. We append it
# as a second gzip cpio segment: the kernel unpacks concatenated compressed
# cpios, so the busybox initramfs from build-kernel.sh does not need rebuilding.
#
# Reuses the firmware Debian already installed -- no extra download. Both board
# variants carry the same SoC GPU, so this runs for tc-eb5 and lite-865 alike.
inject_initramfs_firmware() {
    local want=(qcom/a650_sqe.fw qcom/a650_gmu.bin)
    # optional zap shader; only some firmware trees ship it
    local extra
    for extra in qcom/a650_zap.mbn qcom/a650_zap.mdt; do
        [[ -e "$ROOTFS/lib/firmware/$extra" || -e "$ROOTFS/usr/lib/firmware/$extra" ]] \
            && want+=("$extra")
    done

    local stage="$WORKSPACE/initramfs-fw"
    rm -rf "$stage"
    local f src got=0
    for f in "${want[@]}"; do
        src="$ROOTFS/lib/firmware/$f"
        [[ -e "$src" ]] || src="$ROOTFS/usr/lib/firmware/$f"
        if [[ -e "$src" ]]; then
            install -D "$src" "$stage/lib/firmware/$f"
            echo "  + initramfs firmware: $f"
            got=1
        else
            echo "  WARNING: $f not found; GPU may fail to init" >&2
        fi
    done
    if (( ! got )); then
        echo "  WARNING: no GPU firmware staged for the initramfs" >&2
        return 0
    fi

    # Append a second, independently-gzipped cpio segment.
    ( cd "$stage" && find . -print0 \
        | cpio --null -o --format=newc 2>/dev/null | gzip -9 ) \
        >> "$ART/initramfs.cpio.gz"
    rm -rf "$stage"
    echo "initramfs now $(stat -c%s "$ART/initramfs.cpio.gz") bytes (with GPU firmware)"

    # Keep the spare copy in the rootfs consistent with what goes into boot.img.
    cp -v "$ART/initramfs.cpio.gz" "$ROOTFS/boot/initramfs.cpio.gz"
}
inject_initramfs_firmware

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

# Bring every wired port up with DHCP.
#
# NOTE: match by PREFIX, not by name. systemd predictable naming is active
# (there is no net.ifnames=0 on the kernel command line), so the ports are
# never called eth0/eth1:
#   - EB5:        PCIe RTL8168s behind the ASM2806  -> enp1s0 / enp2s0
#   - slim board: USB RTL8153                       -> enx302146000351 (MAC)
# The old 20-eth0.network / 20-eth1.network matched neither, so networkd never
# took ownership of the link and it just sat there, never even brought up:
#   2: enx302146000351: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN
# en* / eth* covers both boards and both naming schemes, and cannot match wifi
# (wl*), bridges (docker0, br-*) or veth pairs.
#
# RequiredForOnline=no: this image runs on boards with two, one or zero cables
# plugged in, so systemd-networkd-wait-online must not stall the boot waiting
# for carrier on a port that will never get one.
install -d -m 0755 "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/20-wired.network" <<'EOF'
[Match]
Name=en* eth*

[Link]
RequiredForOnline=no

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDomains=yes
RouteMetric=100
EOF
chroot "$ROOTFS" systemctl enable systemd-networkd 2>&1 | tee -a "$LOGDIR/rootfs-misc.log" || true
chroot "$ROOTFS" systemctl enable systemd-resolved 2>&1 | tee -a "$LOGDIR/rootfs-misc.log" || true
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"

# Let unprivileged users ping. iputils-ping prefers an ICMP datagram socket
# (SOCK_DGRAM), which needs no capability at all -- but only if the caller's
# gid falls in net.ipv4.ping_group_range, and Debian ships that as the empty
# range "1 0". Widening it means `ping` works for the debian user even if the
# binary's cap_net_raw is ever lost. (mkrootfs-image.sh also preserves the
# capability via tar --xattrs; this is the belt to that suspenders.)
install -d -m 0755 "$ROOTFS/etc/sysctl.d"
cat > "$ROOTFS/etc/sysctl.d/10-ping-group.conf" <<'EOF'
# Allow all gids to open ICMP echo (datagram) sockets, so ping works without
# cap_net_raw / setuid. Range is "min max" (inclusive).
net.ipv4.ping_group_range = 0 2147483647
EOF

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
