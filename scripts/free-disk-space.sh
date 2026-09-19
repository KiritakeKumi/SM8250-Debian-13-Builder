#!/usr/bin/env bash
# Free disk space on a GitHub-hosted runner, without assuming x86.
#
# Why this exists instead of descriptinc/free-disk-space:
#   that action runs `apt-get remove -y ... google-chrome-stable ...` with no
#   `|| true`. google-chrome-stable is x86-only, so on ubuntu-24.04-arm apt
#   aborts with "E: Unable to locate package" and the whole step fails.
#
# The arm64 runner has only ~14 GiB total, and a kernel build + rootfs + image
# needs roughly 8-10 GiB on top of the OS. So this is deliberately thorough.
#
# Rules:
#   - remove an apt package only if dpkg says it is installed
#   - remove a directory only if it exists
#   - never fail the job because something was already absent
#
# Usage: scripts/free-disk-space.sh
set -uo pipefail

log() { printf '\n=== %s\n' "$*"; }

# df on / plus every other real local filesystem, so we see /mnt if it exists.
report_disk() {
    local label="$1"
    echo "$label"
    df -h --output=target,size,used,avail,pcent -x tmpfs -x devtmpfs -x overlay 2>/dev/null \
        | awk 'NR==1 || ($1 !~ /^\/(run|sys|proc|dev)/)'
}

START_AVAIL_KB=$(df -Pk / | awk 'NR==2 {print $4}')
report_disk "---- disk BEFORE ----"

# ---------------------------------------------------------------------------
# 1. apt packages (only if actually installed)
# ---------------------------------------------------------------------------
log "removing large apt packages"

# NOTE: no google-chrome-stable here on purpose -- see the header comment.
PKG_PATTERNS=(
    '^aspnetcore-.*'
    '^dotnet-.*'
    '^llvm-.*'
    '^clang-.*'
    '^mongodb-.*'
    '^mysql-.*'
    '^postgresql-.*'
    'php.*'
    azure-cli
    firefox
    powershell
    mono-devel
    libgl1-mesa-dri
    postgresql-common
    swift
)

installed=()
for pat in "${PKG_PATTERNS[@]}"; do
    while read -r pkg; do
        [[ -n "$pkg" ]] && installed+=("$pkg")
    done < <(dpkg-query -W -f='${Package}\n' "$pat" 2>/dev/null || true)
done

if (( ${#installed[@]} > 0 )); then
    echo "  removing ${#installed[@]} installed package(s)"
    sudo apt-get remove -y -f "${installed[@]}" >/dev/null 2>&1 || true
else
    echo "  nothing to remove"
fi

# These live outside apt on some images; ignore failures.
for p in google-cloud-sdk google-cloud-cli; do
    sudo apt-get remove -y "$p" >/dev/null 2>&1 || true
done

sudo apt-get autoremove -y >/dev/null 2>&1 || true
sudo apt-get clean >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 2. big toolchain directories
# ---------------------------------------------------------------------------
log "removing large toolchain directories"

DIRS_TO_REMOVE=(
    /usr/share/dotnet            # .NET SDKs (several versions)
    /usr/share/swift             # Swift toolchain
    /usr/local/share/vcpkg       # vcpkg
    /opt/ghc                     # Haskell
    /usr/local/.ghcup            # Haskell (newer images)
    /home/linuxbrew              # Homebrew
    /usr/local/share/powershell  # PowerShell
    /opt/microsoft               # PowerShell / .NET bits
    /usr/local/lib/android       # Android SDK (not on arm64, but harmless)
    /usr/local/share/chromium
    /opt/google
    /usr/lib/jvm                 # JDKs -- we only build C
    /usr/local/go
    /usr/local/rustup
    /usr/local/cargo
    /opt/hostedtoolcache/CodeQL
    /usr/share/swift
)

for d in "${DIRS_TO_REMOVE[@]}"; do
    if [[ -e "$d" ]]; then
        sz="$(sudo du -sh "$d" 2>/dev/null | cut -f1 || echo '?')"
        sudo rm -rf "$d" 2>/dev/null || true
        echo "  removed $d ($sz)"
    fi
done

# ---------------------------------------------------------------------------
# 3. tool cache (Go/Node/Python/Ruby versions we do not use)
# ---------------------------------------------------------------------------
log "clearing tool cache"
if [[ -n "${AGENT_TOOLSDIRECTORY:-}" && -d "${AGENT_TOOLSDIRECTORY:-}" ]]; then
    sz="$(sudo du -sh "$AGENT_TOOLSDIRECTORY" 2>/dev/null | cut -f1 || echo '?')"
    # keep nothing: our build only needs the system gcc/python3
    sudo find "$AGENT_TOOLSDIRECTORY" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    echo "  cleared $AGENT_TOOLSDIRECTORY ($sz)"
else
    echo "  AGENT_TOOLSDIRECTORY not set or missing; skipping"
fi

# ---------------------------------------------------------------------------
# 4. docker images
# ---------------------------------------------------------------------------
log "pruning docker"
if command -v docker >/dev/null 2>&1; then
    sudo docker image prune --all --force >/dev/null 2>&1 || true
    echo "  pruned"
else
    echo "  docker not present"
fi

# ---------------------------------------------------------------------------
# 5. swap file (frees the backing file)
# ---------------------------------------------------------------------------
log "removing swap"
sudo swapoff -a 2>/dev/null || true
sudo rm -f /mnt/swapfile /swapfile 2>/dev/null || true

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
END_AVAIL_KB=$(df -Pk / | awk 'NR==2 {print $4}')
FREED_KB=$(( END_AVAIL_KB - START_AVAIL_KB ))

log "result"
report_disk "---- disk AFTER ----"
if (( FREED_KB > 0 )); then
    echo "freed on /: $(numfmt --to=iec-i --suffix=B $((FREED_KB * 1024)))"
else
    echo "freed on /: nothing (already clean, or accounting has not settled)"
fi

# ---------------------------------------------------------------------------
# Hard floor.
#
# Rough needs:
#   kernel source extracted   ~1.5 GiB
#   kernel build tree         ~2.5 GiB
#   module staging            ~0.3 GiB
#   rootfs tree               ~1.5 GiB
#   rootfs image (actual)     ~2.0 GiB
#   boot images + misc        ~0.2 GiB
#   --------------------------------
#   total                     ~8 GiB
# ---------------------------------------------------------------------------
NEED_KB=$(( 8 * 1024 * 1024 ))
if (( END_AVAIL_KB < NEED_KB )); then
    echo
    echo "WARNING: only $(( END_AVAIL_KB / 1024 / 1024 )) GiB free on /; the build wants ~8 GiB." >&2
    echo "         The arm64 runner has a 14 GiB disk. If the build hits ENOSPC:" >&2
    echo "           - lower rootfs_size_mb (a minimal rootfs is ~1.5 GiB)" >&2
    echo "           - or use a larger runner / self-hosted runner" >&2
fi

exit 0
