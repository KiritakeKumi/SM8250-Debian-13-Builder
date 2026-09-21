#!/usr/bin/env bash
# Resolve a kernel version string into the git tag and repo that actually
# carries it, and print them as KEY=VALUE lines for `eval` (--format=env) or
# for a human/log (--format=kv, the default).
#
# This exists because the naive one-liner
#
#     TAG="v${KERNEL_VERSION%.*}"
#
# is wrong for a bare "7.2": ${V%.*} strips ".2", leaving "v7", and
# `git fetch refs/tags/v7` fails with
#     fatal: couldn't find remote ref refs/tags/v7
#
# There is a second trap: stable releases (6.18.35, 7.2.6, ...) are NOT tagged
# in torvalds/linux -- only in gregkh/linux. A bare major.minor release (7.2)
# IS tagged in both.
#
# Usage:
#   scripts/resolve-kernel-ref.sh 7.2.6
#   scripts/resolve-kernel-ref.sh 7.2 --format=env
#
# Outputs (default --format=kv):
#   KERNEL_TAG=v7.2.6
#   KERNEL_REPO=https://github.com/gregkh/linux.git
#   KERNEL_SERIES=v7.x
#   KERNEL_MAKEVERSION=7.2.6   <- what `make kernelversion` prints (7.2 -> 7.2.0)
#
# NOTE: --format=env is consumed with `eval`, so every value is printed
# shell-quoted (printf %q). KERNEL_KIND contains spaces ("major.minor
# release"); emitting it raw made eval parse the line as
#     KERNEL_KIND=major.minor release
# i.e. an assignment plus the command `release`, which aborted the step with
#     line 13: release: command not found        (exit 127)
set -euo pipefail

KVER="${1:-}"
FORMAT="${2:---format=kv}"
# tolerate the separated spelling: --format env
[[ "$FORMAT" == "--format" ]] && FORMAT="--format=${3:-kv}"
[[ -n "$KVER" ]] || { echo "usage: $0 <kernel-version> [--format=kv|--format=env]" >&2; exit 2; }

case "$FORMAT" in
    --format=env|--format=kv) ;;
    # Never fall through to kv silently: eval'ing the human-readable format
    # would run its first field ("version") as a command.
    *) echo "ERROR: unknown format '$FORMAT' (use --format=kv or --format=env)" >&2; exit 2 ;;
esac

# Reject anything that is not major[.minor[.patch]]
if ! [[ "$KVER" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "ERROR: '$KVER' is not a kernel version like 7.2 or 6.18.35" >&2
    exit 2
fi

KMAJOR="${KVER%%.*}"                 # 6 / 7
series="v${KMAJOR}.x"                # v6.x / v7.x   (kernel.org layout)
tag="v$KVER"                         # v6.18.35 / v7.2

# What the source tree will call itself.
#
# `make kernelversion` always prints VERSION.PATCHLEVEL.SUBLEVEL, and the
# v7.2 tag carries SUBLEVEL = 0 -- so a tree checked out at v7.2 reports
# "7.2.0", not "7.2". Comparing it to the requested "7.2" made fetch-kernel.sh
# throw away a perfectly good tree from every source in turn:
#     rejecting .../work/src/linux-7.2: version is '7.2.0', wanted '7.2'
# kernel.org still names the tarball linux-7.2.tar.xz and the tag v7.2, so
# only the *reported* version needs the third component.
if [[ "$KVER" == *.*.* ]]; then
    makeversion="$KVER"              # 6.18.35 -> 6.18.35
else
    makeversion="$KVER.0"            # 7.2     -> 7.2.0
fi

# Stable point releases live in gregkh/linux. A bare major.minor exists in
# both trees, but gregkh's is the maintained one, so prefer it uniformly.
if [[ "$KVER" == *.*.* ]]; then
    repo="https://github.com/gregkh/linux.git"
    kind="stable point release"
else
    repo="https://github.com/gregkh/linux.git"
    kind="major.minor release"
fi

if [[ "$FORMAT" == "--format=env" ]]; then
    # %q, not plain echo: the caller does `eval "$(...)"`.
    printf 'KERNEL_TAG=%q\n'         "$tag"
    printf 'KERNEL_REPO=%q\n'        "$repo"
    printf 'KERNEL_SERIES=%q\n'      "$series"
    printf 'KERNEL_MAKEVERSION=%q\n' "$makeversion"
    printf 'KERNEL_KIND=%q\n'        "$kind"
else
    printf '%-16s %s\n' "version" "$KVER"
    printf '%-16s %s\n' "tag" "$tag"
    printf '%-16s %s\n' "repo" "$repo"
    printf '%-16s %s\n' "series" "$series"
    printf '%-16s %s\n' "makeversion" "$makeversion"
    printf '%-16s %s\n' "kind" "$kind"
fi
