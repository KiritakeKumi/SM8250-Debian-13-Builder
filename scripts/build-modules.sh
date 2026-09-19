#!/usr/bin/env bash
# Build the out-of-tree board helper modules against the kernel output tree.
#
# These modules are what actually make the wired NICs enumerate on this board:
#   tc-eb5-pcie-helper  - GPIO power/reset sequencing + a GPIO PERST provider
#                         that the *unmodified* mainline qcom-pcie driver uses,
#                         plus a late-bind gate so r8169 probes after the host.
#
# Inputs:  WORKSPACE, KERNEL_VERSION
# Outputs: $WORKSPACE/artifacts/modules/*.ko
set -euo pipefail

: "${WORKSPACE:?WORKSPACE not set}"
: "${KERNEL_VERSION:?KERNEL_VERSION not set}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KSRC="$WORKSPACE/src/linux-$KERNEL_VERSION"
KDIR="$WORKSPACE/build/linux"
ART="$WORKSPACE/artifacts"
LOGDIR="$WORKSPACE/logs"
MODSRC="$REPO_ROOT/modules/tc-eb5"
BUILDDIR="$WORKSPACE/build/modules"

test -f "$KDIR/.config" || { echo "kernel not configured yet ($KDIR/.config)" >&2; exit 1; }

mkdir -p "$ART/modules" "$LOGDIR"
rm -rf "$BUILDDIR"
mkdir -p "$BUILDDIR"
cp -v "$MODSRC"/* "$BUILDDIR/"

echo "building external modules against $KDIR"
make -C "$KSRC" O="$KDIR" M="$BUILDDIR" ARCH=arm64 modules 2>&1 | tee "$LOGDIR/modules-build.log"

shopt -s nullglob
built=("$BUILDDIR"/*.ko)
shopt -u nullglob
if [[ ${#built[@]} -eq 0 ]]; then
    echo "ERROR: no .ko produced" >&2
    exit 1
fi

for ko in "${built[@]}"; do
    echo "built: $ko"
    aarch64-linux-gnu-strip --strip-debug "$ko" 2>/dev/null || strip --strip-debug "$ko" 2>/dev/null || true
    cp -v "$ko" "$ART/modules/"
done

ls -lh "$ART/modules"
