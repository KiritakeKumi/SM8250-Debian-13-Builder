#!/usr/bin/env bash
# Resolve a kernel version string into the git tag and repo that actually
# carries it, and print them as KEY=VALUE lines for `eval` or $GITHUB_OUTPUT.
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
#   scripts/resolve-kernel-ref.sh 7.2 --format env
#
# Outputs (default --format kv):
#   KERNEL_TAG=v7.2.6
#   KERNEL_REPO=https://github.com/gregkh/linux.git
#   KERNEL_SERIES=v7.x
set -euo pipefail

KVER="${1:-}"
FORMAT="${2:---format=kv}"
[[ -n "$KVER" ]] || { echo "usage: $0 <kernel-version>" >&2; exit 2; }

# Reject anything that is not major[.minor[.patch]]
if ! [[ "$KVER" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "ERROR: '$KVER' is not a kernel version like 7.2 or 6.18.35" >&2
    exit 2
fi

KMAJOR="${KVER%%.*}"                 # 6 / 7
series="v${KMAJOR}.x"                # v6.x / v7.x   (kernel.org layout)
tag="v$KVER"                         # v6.18.35 / v7.2

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
    echo "KERNEL_TAG=$tag"
    echo "KERNEL_REPO=$repo"
    echo "KERNEL_SERIES=$series"
    echo "KERNEL_KIND=$kind"
else
    printf '%-16s %s\n' "version" "$KVER"
    printf '%-16s %s\n' "tag" "$tag"
    printf '%-16s %s\n' "repo" "$repo"
    printf '%-16s %s\n' "series" "$series"
    printf '%-16s %s\n' "kind" "$kind"
fi
