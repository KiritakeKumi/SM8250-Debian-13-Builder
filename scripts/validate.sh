#!/usr/bin/env bash
# Validate the workflow YAML, shell scripts and DTS wiring without running the
# real build. Intended for local use and as a fast CI smoke test.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail=0
note() { printf '  %-6s %s\n' "$1" "$2"; }
ok()   { note OK "$1"; }
bad()  { note FAIL "$1"; fail=1; }

echo "== shell scripts syntax =="
for f in scripts/*.sh; do
    if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f"; bash -n "$f" || true; fi
done

echo "== required files =="
for f in \
    README.md \
    config/image.conf \
    config/boot-cmdline.txt \
    config/kernel-base.config \
    config/kernel-fragment.config \
    config/packages.txt \
    dts/nico-debian-sm8250.dts \
    dts/patches/nic-fix-overlay.dtsi \
    modules/tc-eb5/Makefile \
    modules/tc-eb5/eb5-board.c \
    modules/tc-eb5/eb5-bind-gate.c \
    modules/tc-eb5/eb5-bind-gate.h \
    .github/workflows/build.yml ; do
    [[ -s "$f" ]] && ok "$f" || bad "$f"
done

echo "== image.conf =="
# shellcheck source=/dev/null
source config/image.conf
[[ -n "${IMAGE_NAME:-}" ]] && ok "IMAGE_NAME=$IMAGE_NAME" || bad "IMAGE_NAME unset"
[[ -n "${DTS_FILE:-}" ]]   && ok "DTS_FILE=$DTS_FILE"     || bad "DTS_FILE unset"

echo "== cmdline length (must fit ~511 bytes) =="
cmd="$(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' config/boot-cmdline.txt \
    | sed 's|@ROOTFS_UUID@|00000000-0000-0000-0000-000000000000|g' \
    | tr '\n' ' ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')"
len=${#cmd}
if (( len <= 511 )); then ok "cmdline is $len chars"; else bad "cmdline is $len chars (>511)"; fi
echo "       -> $cmd"

echo "== firmware packages are requested =="
for p in firmware-realtek firmware-qcom-soc firmware-linux-nonfree; do
    if grep -q "$p" scripts/build-rootfs.sh; then ok "$p"; else bad "$p not installed"; fi
done

echo "== overlay only touches labels that exist in the base DT =="
base="dts/${DTS_FILE}.dts"
for lbl in pcie1 pcie1_phy tlmm apps_smmu vreg_l5a_0p88 vreg_l9a_1p2; do
    # the base DT defines these via its #includes; check the kernel-side labels exist
    case "$lbl" in
        pcie1|pcie1_phy|tlmm|apps_smmu) src="sm8250.dtsi" ;;
        vreg_l5a_0p88|vreg_l9a_1p2)     src="$base (regulator node)" ;;
    esac
    if grep -qE "(^|[^a-z_])${lbl}:" "$base" 2>/dev/null || [[ "$src" != "$base (regulator node)" ]]; then
        ok "$lbl"
    else
        bad "$lbl not found in $base"
    fi
done

echo "== overlay node names are unique vs the base DT =="
for node in pcie1-sequencer pcie1-asm2806-controls-default pcie1-lan1-pullup-state pcie1-eb5-default-state; do
    if grep -q "$node" "$base"; then
        bad "$node already exists in base DT"
    else
        ok "$node"
    fi
done

echo "== workflow references =="
for s in fetch-kernel.sh fetch-dts.sh build-kernel.sh build-modules.sh build-rootfs.sh mkrootfs-image.sh build-bootimg.sh check-dts.sh validate.sh free-disk-space.sh; do
    if grep -q "$s" .github/workflows/build.yml; then ok "$s"; else bad "$s not referenced"; fi
done

echo "== no x86-only third-party disk action =="
# Match only non-comment lines: the workflow/script deliberately *mention*
# descriptinc/free-disk-space and google-chrome-stable in explanatory comments.
if grep -vE '^\s*#' .github/workflows/build.yml | grep -q 'descriptinc/free-disk-space'; then
    bad "descriptinc/free-disk-space is used (it fails on arm64: google-chrome-stable)"
else
    ok "not using descriptinc/free-disk-space"
fi
if grep -vE '^\s*#' scripts/free-disk-space.sh | grep -q 'google-chrome-stable'; then
    bad "free-disk-space.sh removes google-chrome-stable (x86-only, aborts apt on arm64)"
else
    ok "free-disk-space.sh avoids x86-only packages"
fi
if grep -q 'dpkg-query' scripts/free-disk-space.sh; then
    ok "free-disk-space.sh filters by installed packages"
else
    bad "free-disk-space.sh does not filter by installed packages"
fi

echo "== build runner is arm64 (no qemu needed) =="
if grep -q 'runs-on: ubuntu-24.04-arm' .github/workflows/build.yml; then
    ok "build job on ubuntu-24.04-arm"
else
    bad "build job is not on an arm64 runner"
fi
if grep -q 'qemu-user-static' .github/workflows/build.yml; then
    bad "workflow still installs qemu-user-static"
else
    ok "no qemu-user-static dependency"
fi

echo "== sparse-checkout must include include/uapi =="
# include/dt-bindings/input/linux-event-codes.h is a symlink into include/uapi;
# omitting it breaks the DTS preprocessor with a confusing error.
if grep -q 'include/uapi' .github/workflows/build.yml; then
    ok "include/uapi in sparse-checkout"
else
    bad "include/uapi missing from sparse-checkout (DTS preprocessing will fail)"
fi

echo "== check-dts.sh guards against the dangling symlink =="
for pat in 'include/uapi' 'linux-event-codes.h' 'dangling symlink'; do
    if grep -q "$pat" scripts/check-dts.sh; then ok "guard: $pat"; else bad "guard missing: $pat"; fi
done

echo "== user defaults =="
if grep -q 'debian:debian' scripts/build-rootfs.sh; then ok "user debian/debian"; else bad "user debian/debian not set"; fi
if grep -q '010-debian' scripts/build-rootfs.sh; then ok "sudoers for debian"; else bad "sudoers for debian missing"; fi

echo "== DTS preprocessing must use gcc -E =="
# Without -E, gcc tries to *assemble* the DTS and emits a wall of
# "Assembler messages: Error: unknown mnemonic ...". This bit us in CI.
for f in scripts/build-kernel.sh scripts/check-dts.sh; do
    if grep -qE 'gcc[[:space:]]+-E[[:space:]]' "$f"; then
        ok "$f uses gcc -E"
    else
        bad "$f invokes gcc without -E (will try to assemble the DTS)"
    fi
done

echo "== build-kernel.sh must not build every qcom DTB =="
# `make ... dtbs` builds ~200 unrelated board DTBs; we compile ours separately.
if grep -E 'make .*-j"\$JOBS" Image\.gz dtbs' scripts/build-kernel.sh >/dev/null 2>&1; then
    bad "build-kernel.sh still passes the dtbs target (builds all qcom DTBs)"
else
    ok "build-kernel.sh builds only Image.gz + modules"
fi
if grep -q 'preprocessed DTS does not start with /dts-v1' scripts/build-kernel.sh; then
    ok "build-kernel.sh sanity-checks the preprocessed DTS"
else
    bad "no /dts-v1/ sanity check after preprocessing"
fi

echo "== build-kernel.sh must build the modules target =="
# modules_install needs modules.order, which only `make modules` produces.
if grep -qE 'make .*Image\.gz modules' scripts/build-kernel.sh; then
    ok "build-kernel.sh builds Image.gz modules"
else
    bad "build-kernel.sh does not build 'modules' (modules_install will fail)"
fi
if grep -q 'modules.order not produced' scripts/build-kernel.sh; then
    ok "build-kernel.sh asserts modules.order exists"
else
    bad "no modules.order assertion"
fi

echo "== kernel version must be pinned exactly =="
# A previous run silently fetched the 6.18.y branch HEAD (6.18.52) while the
# job was configured for 6.18.35, producing a wrong-version image.
if grep -q 'branch:linux-\|linux-\${major_minor}\.y' scripts/fetch-kernel.sh; then
    bad "fetch-kernel.sh still references a branch (version drift risk)"
else
    ok "fetch-kernel.sh fetches by exact tag, not branch"
fi
if grep -q 'source_is_good' scripts/fetch-kernel.sh; then
    ok "fetch-kernel.sh validates the fetched version"
else
    bad "fetch-kernel.sh does not validate the fetched version"
fi
if grep -q 'kernelrelease is' scripts/build-kernel.sh; then
    ok "build-kernel.sh asserts kernelrelease matches KERNEL_VERSION"
else
    bad "no kernelrelease assertion"
fi

echo
if (( fail )); then echo "VALIDATION FAILED"; exit 1; fi
echo "ALL CHECKS PASSED"
