#!/usr/bin/env bash
# Fetch the kernel source for $KERNEL_VERSION.
#
# Two ways to get it, in order of preference:
#
#   1. The kernel.org release tarball (fast, ~150 MB, checksummed).
#   2. A shallow clone of the matching stable branch (slower, but survives
#      kernel.org being unavailable and always carries the newest backports).
#
# Why we care about the stable series specifically:
#   modules/tc-eb5/eb5-bind-gate.c calls device_has_driver_override(). That
#   helper (plus the nested `struct device.driver_override { name; lock; }`)
#   landed upstream in 7.0 and was then backported into the 6.18 stable series
#   between 6.18.20 and 6.18.30. A mainline *release* tag like v6.18 does NOT
#   have it; a stable tag like v6.18.30+ does.
#
#   The board's working Armbian kernel is built from the 6.18 stable branch and
#   has the backport, which is why the shipped tc-eb5-pcie-helper.ko links
#   against device_has_driver_override.
#
# So: after fetching, we verify the helper is present and fail early with a
# clear message if it is not, instead of producing a confusing compile error.
set -euo pipefail

: "${WORKSPACE:?WORKSPACE not set}"
: "${KERNEL_VERSION:?KERNEL_VERSION not set}"

SRC_DIR="$WORKSPACE/src"
KSRC="$SRC_DIR/linux-$KERNEL_VERSION"
LOGDIR="$WORKSPACE/logs"
mkdir -p "$SRC_DIR" "$LOGDIR"

major_minor="${KERNEL_VERSION%.*}"          # 6.18.35 -> 6.18
stable_branch="linux-${major_minor}.y"      # linux-6.18.y
series="v${major_minor}.x"                  # v6.18.x

if [[ -f "$KSRC/Makefile" ]]; then
    echo "kernel source already present at $KSRC"
    grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION) =' "$KSRC/Makefile" || true
    exit 0
fi

have_helper() {
    grep -rqs 'device_has_driver_override' "$1/include/linux/device.h" 2>/dev/null
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

    if ! have_helper "$KSRC"; then
        echo "   NOTE: this tarball lacks device_has_driver_override();"
        echo "         falling back to the stable branch"
        rm -rf "$KSRC"
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
        [[ $attempt -eq 5 ]] && { echo "   all fetch attempts failed"; rm -rf "$worktree"; return 1; }
        sleep 15
    done

    git -C "$worktree" checkout -q FETCH_HEAD

    if ! have_helper "$worktree"; then
        echo "   stable branch head still lacks the helper; giving up"
        rm -rf "$worktree"
        return 1
    fi

    mv "$worktree" "$KSRC"
    return 0
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
if ! try_tarball; then
    if ! try_branch; then
        cat >&2 <<EOF

ERROR: could not obtain a suitable kernel source for $KERNEL_VERSION.

modules/tc-eb5/eb5-bind-gate.c needs device_has_driver_override(), which is
present in the 6.18 stable series from about 6.18.30 onwards (and in 7.0+).
Pick KERNEL_VERSION >= 6.18.30, or set WITH_NIC_FIX=false to build without the
board helper modules.
EOF
        exit 1
    fi
fi

test -f "$KSRC/Makefile" || { echo "kernel source missing at $KSRC" >&2; exit 1; }

echo
echo "== kernel source ready =="
grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION) =' "$KSRC/Makefile"
echo "kernelversion: $(make -s -C "$KSRC" kernelversion 2>/dev/null || echo unknown)"
echo "device_has_driver_override(): present"
