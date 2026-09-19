#!/usr/bin/env bash
# Download and unpack the pristine kernel.org tarball for $KERNEL_VERSION.
set -euo pipefail

: "${WORKSPACE:?WORKSPACE not set}"
: "${KERNEL_VERSION:?KERNEL_VERSION not set}"

SRC_DIR="$WORKSPACE/src"
KSRC="$SRC_DIR/linux-$KERNEL_VERSION"
LOGDIR="$WORKSPACE/logs"
mkdir -p "$SRC_DIR" "$LOGDIR"

if [[ -f "$KSRC/Makefile" ]]; then
    echo "kernel source already present at $KSRC"
    exit 0
fi

# kernel.org uses v6.x/ for 6.x releases
major_series="v${KERNEL_VERSION%%.*}.x"
tarball="linux-$KERNEL_VERSION.tar.xz"
url="https://cdn.kernel.org/pub/linux/kernel/$major_series/$tarball"

echo "fetching $url"
curl -fL --retry 5 --retry-delay 10 -o "$SRC_DIR/$tarball" "$url"

# kernel.org publishes per-tarball sha256 in the same directory listing; verify if available
if curl -fsL --retry 3 -o "$SRC_DIR/$tarball.sha256" "$url.sha256" 2>/dev/null; then
    echo "verifying sha256 from kernel.org"
    ( cd "$SRC_DIR" && sha256sum -c "$tarball.sha256" )
else
    echo "no upstream .sha256 published for this tarball; skipping verification"
fi

echo "extracting"
tar -C "$SRC_DIR" -xf "$SRC_DIR/$tarball"
rm -f "$SRC_DIR/$tarball"

test -f "$KSRC/Makefile" || { echo "extraction did not produce $KSRC/Makefile"; exit 1; }
echo "kernel source ready: $KSRC"
