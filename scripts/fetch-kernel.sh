#!/usr/bin/env bash
# Fetch the kernel source for $KERNEL_VERSION.
#
# The version must match EXACTLY. A mismatch is a hard error: the release
# string ends up in the module vermagic and in the artifact names, so silently
# building 6.18.52 when 6.18.35 was asked for produces images that look right
# but carry the wrong kernel.
#
# Order of attempts:
#   1. kernel.org release tarball          (fast, checksummed, exact version)
#   2. shallow clone of the exact git tag  (exact version, survives kernel.org
#                                           being slow or blocked)
# A branch HEAD is deliberately NOT used: that is how a previous run silently
# produced 6.18.52+ while the job was configured for 6.18.35.
#
# Note on the driver_override API: modules/tc-eb5/eb5-bind-gate.c calls
# device_has_driver_override(). That helper (plus the nested
# `struct device.driver_override { name; lock; }` and the removal of
# `struct pci_dev.driver_override`) landed upstream in 7.0 and was backported
# into the 6.18 stable series between 6.18.20 and 6.18.30. Verified present in
# v6.18.35. We assert it after fetching so a bad version fails fast.
set -euo pipefail

: "${WORKSPACE:?WORKSPACE not set}"
: "${KERNEL_VERSION:?KERNEL_VERSION not set}"

SRC_DIR="$WORKSPACE/src"
KSRC="$SRC_DIR/linux-$KERNEL_VERSION"
LOGDIR="$WORKSPACE/logs"
mkdir -p "$SRC_DIR" "$LOGDIR"

major_minor="${KERNEL_VERSION%.*}"          # 6.18.35 -> 6.18
series="v${major_minor}.x"                  # v6.18.x
tag="v$KERNEL_VERSION"                      # v6.18.35

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have_helper() {
    grep -q 'device_has_driver_override' "$1/include/linux/device.h" 2>/dev/null
}

# Print the base version of a source tree (no LOCALVERSION), e.g. "6.18.35".
source_version() {
    make -s -C "$1" kernelversion 2>/dev/null || echo unknown
}

# Is the tree at $1 usable for us?
source_is_good() {
    local tree="$1"
    [[ -f "$tree/Makefile" ]] || return 1
    have_helper "$tree" || return 1
    local v
    v="$(source_version "$tree")"
    if [[ "$v" != "$KERNEL_VERSION" ]]; then
        echo "   rejecting $tree: version is '$v', wanted '$KERNEL_VERSION'"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 0. Reuse an existing tree ONLY if it is the right version.
#    (A previous run's bad fallback may have left the wrong source here, and
#    the GitHub Actions cache would faithfully restore it.)
# ---------------------------------------------------------------------------
if [[ -f "$KSRC/Makefile" ]]; then
    if source_is_good "$KSRC"; then
        echo "kernel source already present and correct: $KSRC"
        grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION) =' "$KSRC/Makefile" || true
        exit 0
    fi
    echo "existing $KSRC is not usable; refetching"
    rm -rf "$KSRC"
fi

# ---------------------------------------------------------------------------
# Attempt 1: kernel.org tarball
# ---------------------------------------------------------------------------
try_tarball() {
    local tarball="linux-$KERNEL_VERSION.tar.xz"
    local url="https://cdn.kernel.org/pub/linux/kernel/$series/$tarball"

    echo "== attempt 1: kernel.org tarball =="
    echo "   $url"
    rm -f "$SRC_DIR/$tarball"
    if ! curl -fL --retry 5 --retry-delay 10 --connect-timeout 30 \
              --max-time 1800 \
              -o "$SRC_DIR/$tarball" "$url"; then
        echo "   download failed"
        rm -f "$SRC_DIR/$tarball"
        return 1
    fi
    echo "   downloaded $(stat -c%s "$SRC_DIR/$tarball") bytes"

    # kernel.org publishes sha256sums.asc rather than per-file .sha256, so this
    # is best-effort; a missing checksum is not fatal.
    if curl -fsL --retry 3 --connect-timeout 30 \
             -o "$SRC_DIR/$tarball.sha256" "$url.sha256" 2>/dev/null; then
        echo "   verifying sha256"
        if ! ( cd "$SRC_DIR" && sha256sum -c "$tarball.sha256" ); then
            echo "   checksum mismatch"
            rm -f "$SRC_DIR/$tarball" "$SRC_DIR/$tarball.sha256"
            return 1
        fi
        rm -f "$SRC_DIR/$tarball.sha256"
    fi

    echo "   extracting"
    if ! tar -C "$SRC_DIR" -xf "$SRC_DIR/$tarball"; then
        echo "   extraction failed (truncated download?)"
        rm -rf "$KSRC"
        rm -f "$SRC_DIR/$tarball"
        return 1
    fi
    rm -f "$SRC_DIR/$tarball"

    [[ -f "$KSRC/Makefile" ]] || { echo "   no Makefile after extraction"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# Attempt 2: shallow clone at the exact tag
# ---------------------------------------------------------------------------
try_tag_clone() {
    local remote="$1" name="$2"
    local worktree="$SRC_DIR/.kfetch"

    echo "== attempt 2: $name tag $tag =="
    rm -rf "$worktree"
    if ! git init -q "$worktree"; then return 1; fi
    git -C "$worktree" remote add origin "$remote"

    local attempt
    for attempt in 1 2 3 4 5; do
        echo "   fetch attempt $attempt"
        if git -C "$worktree" fetch --depth 1 --no-tags \
               origin "refs/tags/$tag:refs/tags/$tag" 2>&1; then
            break
        fi
        if [[ $attempt -eq 5 ]]; then
            echo "   all fetch attempts failed"
            rm -rf "$worktree"
            return 1
        fi
        sleep 15
    done

    # Check out the tag itself (not FETCH_HEAD) so setlocalversion sees a tag
    # and does not append a '+' to the release string.
    git -C "$worktree" checkout -q "refs/tags/$tag"

    mv "$worktree" "$KSRC"
    return 0
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
ok=0
if try_tarball && source_is_good "$KSRC"; then
    ok=1
else
    rm -rf "$KSRC"
    for remote_name in \
        "https://github.com/gregkh/linux.git|gregkh/linux" \
        "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git|kernel.org stable" ; do
        remote="${remote_name%%|*}"
        name="${remote_name##*|}"
        if try_tag_clone "$remote" "$name" && source_is_good "$KSRC"; then
            ok=1
            break
        fi
        rm -rf "$KSRC"
    done
fi

if [[ $ok -ne 1 ]]; then
    cat >&2 <<EOF

ERROR: could not obtain a usable Linux $KERNEL_VERSION source tree.

Tried:
  - https://cdn.kernel.org/pub/linux/kernel/$series/linux-$KERNEL_VERSION.tar.xz
  - git tag $tag from gregkh/linux
  - git tag $tag from kernel.org stable

EOF
    exit 1
fi

# ---------------------------------------------------------------------------
# Final assertions
# ---------------------------------------------------------------------------
test -f "$KSRC/Makefile" || { echo "kernel source missing at $KSRC" >&2; exit 1; }

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

actual="$(source_version "$KSRC")"
if [[ "$actual" != "$KERNEL_VERSION" ]]; then
    echo "ERROR: fetched source reports '$actual' but '$KERNEL_VERSION' was requested" >&2
    exit 1
fi

echo
echo "== kernel source ready =="
grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION) =' "$KSRC/Makefile"
echo "kernelversion: $actual"
echo "device_has_driver_override(): present"
