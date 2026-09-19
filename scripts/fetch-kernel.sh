#!/usr/bin/env bash
# Fetch the kernel source for $KERNEL_VERSION from kernel.org.
#
# The tarball is used directly. This works because the driver_override
# backport our out-of-tree module needs is already present in the 6.18 stable
# series by 6.18.35:
#
#   modules/tc-eb5/eb5-bind-gate.c calls device_has_driver_override().
#   That helper -- plus the nested `struct device.driver_override { name; lock; }`
#   and the removal of `struct pci_dev.driver_override` -- landed upstream in
#   7.0 and was backported into the 6.18 stable series between 6.18.20 and
#   6.18.30. Verified present in v6.18.35.
#
#   The board's working Armbian kernel (6.18.35-current-sm8250) exposes exactly
#   this API, and the shipped tc-eb5-pcie-helper.ko references
#   device_has_driver_override, so the two match.
#
# A stable-branch shallow clone is kept as a fallback for when kernel.org is
# unreachable. After fetching we verify the helper is present and fail early
# with a clear message if it is not.
set -euo pipefail

: "${WORKSPACE:?WORKSPACE not set}"
: "${KERNEL_VERSION:?KERNEL_VERSION not set}"

SRC_DIR="$WORKSPACE/src"
KSRC="$SRC_DIR/linux-$KERNEL_VERSION"
LOGDIR="$WORKSPACE/logs"
mkdir -p "$SRC_DIR" "$LOGDIR"

major_minor="${KERNEL_VERSION%.*}"          # 6.18.35 -> 6.18
series="v${major_minor}.x"                  # v6.18.x
stable_branch="linux-${major_minor}.y"      # linux-6.18.y

if [[ -f "$KSRC/Makefile" ]]; then
    echo "kernel source already present at $KSRC"
    grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION) =' "$KSRC/Makefile" || true
    exit 0
fi

have_helper() {
    grep -q 'device_has_driver_override' "$1/include/linux/device.h" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Attempt 1: kernel.org tarball
# ---------------------------------------------------------------------------
try_tarball() {
    local tarball="linux-$KERNEL_VERSION.tar.xz"
    local url="https://cdn.kernel.org/pub/linux/kernel/$series/$tarball"

    echo "== attempt 1: kernel.org tarball =="
    echo "   $url"
    if ! curl -fL --retry 5 --retry-delay 10 --connect-timeout 30 \
              -o "$SRC_DIR/$tarball" "$url"; then
        echo "   download failed"
        return 1
    fi

    if curl -fsL --retry 3 --connect-timeout 30 -o "$SRC_DIR/$tarball.sha256" "$url.sha256" 2>/dev/null; then
        echo "   verifying sha256"
        ( cd "$SRC_DIR" && sha256sum -c "$tarball.sha256" ) || { echo "   checksum mismatch"; return 1; }
    else
        echo "   no upstream .sha256 published; skipping verification"
    fi

    echo "   extracting"
    if ! tar -C "$SRC_DIR" -xf "$SRC_DIR/$tarball"; then
        echo "   extraction failed (truncated download?)"
        rm -rf "$KSRC"
        return 1
    fi
    rm -f "$SRC_DIR/$tarball" "$SRC_DIR/$tarball.sha256"

    if [[ ! -f "$KSRC/Makefile" ]]; then
        echo "   no Makefile after extraction"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Attempt 2: shallow clone of the stable branch
# ---------------------------------------------------------------------------
try_branch() {
    local worktree="$SRC_DIR/.kfetch"

    echo "== attempt 2: stable branch $stable_branch =="
    rm -rf "$worktree"
    git init -q "$worktree"
    git -C "$worktree" remote add origin https://github.com/gregkh/linux.git

    local attempt
    for attempt in 1 2 3 4 5; do
        echo "   fetch attempt $attempt"
        if git -C "$worktree" fetch --depth 1 --no-tags origin "$stable_branch"; then
            break
        fi
        if [[ $attempt -eq 5 ]]; then
            echo "   all fetch attempts failed"
            rm -rf "$worktree"
            return 1
        fi
        sleep 15
    done

    git -C "$worktree" checkout -q FETCH_HEAD
    mv "$worktree" "$KSRC"
    return 0
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
if ! try_tarball; then
    if ! try_branch; then
        echo "ERROR: could not obtain kernel source for $KERNEL_VERSION" >&2
        exit 1
    fi
fi

test -f "$KSRC/Makefile" || { echo "kernel source missing at $KSRC" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Verify the API the out-of-tree module needs is present.
# Fail early with an actionable message instead of a confusing compile error.
# ---------------------------------------------------------------------------
if ! have_helper "$KSRC"; then
    cat >&2 <<EOF

ERROR: $KSRC does not provide device_has_driver_override().

modules/tc-eb5/eb5-bind-gate.c needs it. It is present in the 6.18 stable
series from about 6.18.30 onwards, and in 7.0+. Either:
  - pick KERNEL_VERSION >= 6.18.30, or
  - set WITH_NIC_FIX=false to build without the board helper modules.
EOF
    exit 1
fi

echo
echo "== kernel source ready =="
grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION) =' "$KSRC/Makefile"
echo "kernelversion: $(make -s -C "$KSRC" kernelversion 2>/dev/null || echo unknown)"
echo "device_has_driver_override(): present"
