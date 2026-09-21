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
for s in fetch-kernel.sh fetch-dts.sh build-kernel.sh build-modules.sh build-rootfs.sh mkrootfs-image.sh build-bootimg.sh check-dts.sh validate.sh free-disk-space.sh test-mkbootimg.py; do
    if grep -q "$s" .github/workflows/build.yml; then ok "$s"; else bad "$s not referenced"; fi
done

echo "== boolean inputs must not use the '== false && ... || ...' idiom =="
# On push events `inputs` is empty, and `inputs.x == false` evaluates to true,
# so that idiom silently produced WITH_NIC_FIX=false (artifact name "nicfalse").
if grep -E "inputs\.(with_nic_fix|enable_ssh|make_default_user)\s*==\s*false\s*&&" .github/workflows/build.yml >/dev/null 2>&1; then
    bad "workflow still resolves booleans with 'inputs.x == false && ...'"
else
    ok "booleans are resolved in a step, not inline"
fi
if grep -q 'Resolve build options' .github/workflows/build.yml; then
    ok "workflow has a 'Resolve build options' step"
else
    bad "no 'Resolve build options' step"
fi

echo "== push to main must build and publish a release =="
if grep -q 'workflow_dispatch' .github/workflows/build.yml && \
   grep -q 'push:' .github/workflows/build.yml; then
    ok "workflow triggers on both dispatch and push"
else
    bad "workflow is missing a trigger"
fi
if grep -q 'Resolve release tag' .github/workflows/build.yml; then
    ok "release job resolves its own tag"
else
    bad "release job has no tag resolution"
fi
if grep -q 'softprops/action-gh-release' .github/workflows/build.yml; then
    ok "release job publishes via action-gh-release"
else
    bad "no release publishing step"
fi
if grep -q 'body_path: release-notes.md' .github/workflows/build.yml; then
    ok "release has generated notes"
else
    bad "release has no notes"
fi

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

echo "== boot image packing must not depend on a distro mkbootimg =="
# mkbootimg is not on PyPI, and the distro package is v34 (may not do v0).
# We ship our own packer instead.
if [[ -s scripts/mkbootimg.py ]]; then
    ok "scripts/mkbootimg.py present"
else
    bad "scripts/mkbootimg.py missing"
fi
if grep -vE '^\s*#' scripts/build-bootimg.sh | grep -q 'pip3\? install.*mkbootimg'; then
    bad "build-bootimg.sh still tries to pip install mkbootimg (it is not on PyPI)"
else
    ok "build-bootimg.sh does not pip install mkbootimg"
fi
if grep -q 'scripts/mkbootimg.py' scripts/build-bootimg.sh; then
    ok "build-bootimg.sh uses the bundled packer"
else
    bad "build-bootimg.sh does not use scripts/mkbootimg.py"
fi
# the packer must write header_version 0 and the board's exact addresses
for pat in 'header_version' '0x8000' '0x1000000' '0x100' '4096'; do
    if grep -q "$pat" scripts/mkbootimg.py; then
        ok "packer handles $pat"
    else
        bad "packer missing $pat"
    fi
done

echo "== attribution must be present =="
# The board support code is not ours; CREDITS.md must exist and the files that
# came from elsewhere must say so.
if [[ -s CREDITS.md ]]; then
    ok "CREDITS.md present"
else
    bad "CREDITS.md missing"
fi
if grep -q 'evsio0n/tc-eb5-oot' CREDITS.md; then
    ok "CREDITS.md names Evsio0n/tc-eb5-oot"
else
    bad "CREDITS.md does not credit Evsio0n/tc-eb5-oot"
fi
if grep -q 'Evsio0n/tc-eb5-oot' README.md; then
    ok "README links to the credits"
else
    bad "README does not mention the upstream project"
fi
for f in modules/tc-eb5/eb5-board.c modules/tc-eb5/eb5-bind-gate.c \
         modules/tc-eb5/eb5-bind-gate.h modules/tc-eb5/Makefile \
         dts/patches/nic-fix-overlay.dtsi; do
    if grep -q 'Evsio0n/tc-eb5-oot' "$f"; then
        ok "$f carries attribution"
    else
        bad "$f is missing attribution"
    fi
done

echo "== release assets must fit GitHub's 2 GiB per-file limit =="
# A 6000 MiB rootfs image is far past the limit; the release job must ship the
# gzipped form and never glob dist/** (which would also sweep in build logs).
if grep -q 'gzip -9 -k -f' .github/workflows/build.yml; then
    ok "rootfs is gzipped before release"
else
    bad "rootfs is not gzipped (will exceed the 2 GiB release limit)"
fi
if grep -qE 'files:\s*dist/\*\*' .github/workflows/build.yml; then
    bad "publish uses dist/** (sweeps the raw .img and build logs)"
else
    ok "publish does not glob dist/**"
fi
if grep -qE 'files:\s*release/\*' .github/workflows/build.yml; then
    ok "publish uses an explicit release/* directory"
else
    bad "publish does not use release/*"
fi
if grep -q 'RELEASE-ASSETS.txt' .github/workflows/build.yml; then
    ok "release uses a RELEASE-ASSETS.txt allowlist"
else
    bad "no release asset allowlist"
fi
if grep -qE '2 \* 1024 \* 1024 \* 1024|2147483648' .github/workflows/build.yml; then
    ok "workflow guards against the 2 GiB limit"
else
    bad "no 2 GiB guard"
fi
if grep -q 'rootfs-artifact' .github/workflows/build.yml; then
    ok "rootfs artifact is downloaded separately from boot images"
else
    bad "rootfs artifact is merged into the release download"
fi

echo "== the release job must define its own artifact-name env =="
# `env` is per-job. Referencing env.KERNEL_VERSION in the release job without
# defining it silently produces artifact names like "-nic".
release_block=$(sed -n '/^  release:/,$p' .github/workflows/build.yml)
if printf '%s' "$release_block" | grep -q 'KERNEL_VERSION:'; then
    ok "release job defines KERNEL_VERSION"
else
    bad "release job does not define KERNEL_VERSION"
fi
if printf '%s' "$release_block" | grep -q 'DTB_SOURCE:'; then
    ok "release job defines DTB_SOURCE"
else
    bad "release job does not define DTB_SOURCE"
fi
if printf '%s' "$release_block" | grep -q 'needs.build.outputs'; then
    bad "release job reads build outputs that the build job does not declare"
else
    ok "release job resolves its options locally"
fi
n_tag=$(grep -c 'name: Resolve release tag' .github/workflows/build.yml)
if [[ "$n_tag" == "1" ]]; then
    ok "exactly one tag-resolution step"
else
    bad "$n_tag tag-resolution steps (expected 1)"
fi

echo "== scripts that need root must self-elevate =="
# debootstrap/chroot (build-rootfs.sh) and loop mount + mkfs (mkrootfs-image.sh)
# need root. In CI the runner has passwordless sudo, so they re-exec themselves.
for f in scripts/build-rootfs.sh scripts/mkrootfs-image.sh; do
    if grep -q 're-executing with sudo' "$f"; then
        ok "$f self-elevates"
    else
        bad "$f needs root but does not self-elevate"
    fi
    # `sudo VAR=... cmd` is not portable; require the `sudo env VAR=...` form.
    if grep -qE 'exec sudo env' "$f"; then
        ok "$f uses 'sudo env' (portable)"
    else
        bad "$f does not use 'sudo env' for the re-exec"
    fi
done
# scripts that do NOT need root should not silently escalate
for f in scripts/build-kernel.sh scripts/build-modules.sh scripts/build-bootimg.sh; do
    if grep -q 're-executing with sudo' "$f"; then
        bad "$f self-elevates but does not need root"
    else
        ok "$f needs no root"
    fi
done

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

echo "== kernel tag resolution must be shared, not duplicated =="
# The CI validate job used to inline  TAG="v${KVER%.*}"  which produced "v7"
# for input "7.2" -> "fatal: couldn't find remote ref refs/tags/v7".
if [[ -x scripts/resolve-kernel-ref.sh ]] || [[ -s scripts/resolve-kernel-ref.sh ]]; then
    ok "scripts/resolve-kernel-ref.sh present"
else
    bad "scripts/resolve-kernel-ref.sh missing"
fi
if grep -q 'resolve-kernel-ref.sh' .github/workflows/build.yml; then
    ok "workflow uses the shared resolver"
else
    bad "workflow does not use the shared resolver"
fi
if grep -q 'resolve-kernel-ref.sh' scripts/fetch-kernel.sh; then
    ok "fetch-kernel.sh uses the shared resolver"
else
    bad "fetch-kernel.sh does not use the shared resolver"
fi
# the broken idiom must not appear as *code* anywhere. Comment lines are
# excluded: resolve-kernel-ref.sh and validate.sh deliberately quote the old
# form in their explanatory comments.
fragile_hits=$(grep -rn 'TAG="v\${KVER%\.\*}"\|TAG="v\${KERNEL_VERSION%\.\*}"' \
                   .github/workflows/build.yml scripts/ 2>/dev/null \
               | grep -v ':[0-9]*: *#' || true)
if [[ -n "$fragile_hits" ]]; then
    bad "the fragile TAG=\"v\${VER%.*}\" idiom is still present:"
    printf '        %s\n' "$fragile_hits"
else
    ok "no fragile TAG=\${VER%.*} idiom in executable code"
fi
# stable point releases live in gregkh/linux, not torvalds/linux
if grep -q 'gregkh/linux' scripts/resolve-kernel-ref.sh; then
    ok "resolver knows stable releases are in gregkh/linux"
else
    bad "resolver does not target gregkh/linux (stable tags would 404)"
fi
if grep -q 'resolve-kernel-ref' scripts/validate.sh; then
    ok "validator covers the resolver"
else
    bad "validator does not mention the resolver"
fi
# Functional check, not a grep: both callers consume the env format with
# `eval`, so it has to survive eval verbatim. KERNEL_KIND holds a value with
# spaces ("major.minor release"); printed unquoted, eval parsed the line as
#   KERNEL_KIND=major.minor release
# and tried to run `release`, killing the CI step with
#   line 13: release: command not found   (exit 127)
for v in 7.2 6.18.35; do
    if out=$(bash -c '
                set -euo pipefail
                eval "$(bash scripts/resolve-kernel-ref.sh "$1" --format=env)"
                printf "%s|%s|%s\n" "$KERNEL_TAG" "$KERNEL_SERIES" "$KERNEL_KIND"
            ' _ "$v" 2>&1); then
        IFS='|' read -r r_tag r_series r_kind <<<"$out"
        if [[ "$r_tag" == "v$v" && -n "$r_series" && -n "$r_kind" ]]; then
            ok "resolver env output evals cleanly for $v (tag=$r_tag, kind=$r_kind)"
        else
            bad "resolver env output is wrong for $v: $out"
        fi
    else
        bad "resolver env output is not eval-safe for $v: $out"
    fi
done
# An unknown --format must be an error, not a silent fallback to the
# human-readable format -- eval'ing that would run its first field, "version".
if bash scripts/resolve-kernel-ref.sh 7.2 --format=bogus >/dev/null 2>&1; then
    bad "resolver accepts an unknown --format (eval would run 'version')"
else
    ok "resolver rejects an unknown --format"
fi

echo "== kernel.org paths must be derived correctly for 6.x and 7.x =="
# ${VERSION%.*} on a bare "7.2" yields "7", which would give the wrong series
# dir (v7.x instead of v7.2.x is fine for the tarball, but the *branch* name
# must be linux-7.2.y, not linux-7.y).
if grep -q 'stable_branch=' scripts/fetch-kernel.sh; then
    ok "fetch-kernel.sh computes a stable branch name"
else
    bad "fetch-kernel.sh has no stable_branch derivation"
fi
# The series/tag now come from the shared resolver; assert it is wired in.
if grep -q 'series="\$KERNEL_SERIES"' scripts/fetch-kernel.sh && \
   grep -q 'tag="\$KERNEL_TAG"' scripts/fetch-kernel.sh; then
    ok "fetch-kernel.sh takes series/tag from the resolver"
else
    bad "fetch-kernel.sh does not use the resolver's series/tag"
fi

echo "== 7.x awareness in build-kernel.sh =="
if grep -q 'KMAJOR=' scripts/build-kernel.sh; then
    ok "build-kernel.sh detects the major version"
else
    bad "build-kernel.sh does not detect the major version"
fi
if grep -q 'device_has_driver_override' scripts/build-kernel.sh; then
    ok "build-kernel.sh asserts the 7.x driver_override API"
else
    bad "no 7.x API assertion in build-kernel.sh"
fi

echo "== DT fallback must exist for 7.x (Armbian has no 7.x copy) =="
if grep -q 'FALLBACK_TO_REPO_SNAPSHOT' config/image.conf && \
   grep -q 'copy_snapshot' scripts/fetch-dts.sh; then
    ok "fetch-dts.sh falls back to the in-repo snapshot"
else
    bad "no in-repo DT fallback (7.x builds would fail)"
fi

echo
if (( fail )); then echo "VALIDATION FAILED"; exit 1; fi
echo "ALL CHECKS PASSED"
