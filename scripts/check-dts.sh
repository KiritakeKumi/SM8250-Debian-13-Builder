#!/bin/sh
# Validate the DTS by preprocessing and compiling it, using the actual kernel
# source tree (needed for sm8250.dtsi and dt-bindings).
#
# Usage: scripts/check-dts.sh <path-to-linux-source> [--no-overlay]
#
#   default       tc-eb5 variant: base DTS + dts/patches/nic-fix-overlay.dtsi
#   --no-overlay  lite-865 variant: base DTS only. Asserts the opposite of the
#                 above -- the tree must NOT claim to be an EB5, because
#                 eb5-board.c keys on of_machine_is_compatible("thundercomm,eb5")
#                 and would otherwise drive the board GPIOs on hardware that
#                 has no ASM2806.
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
KSRC="${1:-}"
WITH_OVERLAY=1
if [ "${2:-}" = "--no-overlay" ]; then
    WITH_OVERLAY=0
elif [ -n "${2:-}" ]; then
    echo "usage: $0 <path-to-linux-source-tree> [--no-overlay]" >&2
    exit 2
fi
if [ -z "$KSRC" ] || [ ! -f "$KSRC/Makefile" ]; then
    echo "usage: $0 <path-to-linux-source-tree> [--no-overlay]" >&2
    echo "(a full kernel source tree is needed for sm8250.dtsi and dt-bindings)" >&2
    exit 2
fi

# shellcheck source=/dev/null
. "$REPO_ROOT/config/image.conf"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Preflight: dt-bindings headers must be complete.
#
# include/dt-bindings/input/linux-event-codes.h is a *symlink* into
# include/uapi/linux/. A sparse/partial checkout that omits include/uapi will
# break here with a confusing "linux-event-codes.h: No such file or directory".
# ---------------------------------------------------------------------------
echo "== preflight: dt-bindings completeness =="
missing=0
for h in \
    include/dt-bindings/input/linux-event-codes.h \
    include/dt-bindings/input/input.h \
    include/dt-bindings/clock/qcom,dispcc-sm8150.h \
    include/dt-bindings/clock/qcom,dispcc-sm8350.h \
    include/dt-bindings/clock/qcom,sm8650-dispcc.h \
    include/uapi/linux/input-event-codes.h \
    arch/arm64/boot/dts/qcom/sm8250.dtsi \
    arch/arm64/boot/dts/qcom/pm8150.dtsi \
    arch/arm64/boot/dts/qcom/pm8150b.dtsi \
    arch/arm64/boot/dts/qcom/pm8150l.dtsi ; do
    if [ -e "$KSRC/$h" ]; then
        echo "  OK   $h"
    else
        echo "  MISS $h"
        if [ -L "$KSRC/$h" ]; then
            echo "       (dangling symlink -> $(readlink "$KSRC/$h"))"
        fi
        missing=1
    fi
done
if [ "$missing" = "1" ]; then
    cat >&2 <<'EOF'

ERROR: the kernel source tree is missing dt-bindings headers.

If you fetched it with a sparse/partial checkout, make sure BOTH of these are
included:

    include/dt-bindings
    include/uapi

include/dt-bindings/input/linux-event-codes.h is a symlink into include/uapi,
and pm8150.dtsi pulls it in through dt-bindings/input/input.h.

A full kernel tarball (or `git clone --depth 1`) always has both.
EOF
    exit 1
fi

# ---------------------------------------------------------------------------
# Merge + preprocess + compile
# ---------------------------------------------------------------------------
if [ "$WITH_OVERLAY" = "1" ]; then
    echo "== variant: tc-eb5 (base DTS + nic-fix overlay) =="
    cat "$REPO_ROOT/dts/${DTS_FILE}.dts" \
        "$REPO_ROOT/dts/patches/nic-fix-overlay.dtsi" > "$WORK/merged.dts"
else
    echo "== variant: lite-865 (base DTS only) =="
    cat "$REPO_ROOT/dts/${DTS_FILE}.dts" > "$WORK/merged.dts"
fi
echo "== merged: $(wc -l < "$WORK/merged.dts") lines =="

echo "== preprocess =="
gcc -E -nostdinc \
    -I "$KSRC/scripts/dtc/include-prefixes" \
    -I "$KSRC/arch/arm64/boot/dts/qcom" \
    -I "$KSRC/arch/arm64/boot/dts" \
    -I "$KSRC/include" \
    -undef -D__DTS__ -x assembler-with-cpp \
    -o "$WORK/merged.pre.dts" "$WORK/merged.dts"

# Prefer the dtc built inside the kernel tree (it has the right libfdt), but a
# sparse/header-only checkout will not have it built yet. Fall back to the
# system dtc, which is fine for a syntax + content check.
if [ -x "$KSRC/scripts/dtc/dtc" ]; then
    DTC="$KSRC/scripts/dtc/dtc"
else
    DTC="$(command -v dtc || true)"
fi
if [ -z "$DTC" ]; then
    echo "ERROR: no dtc found (neither \$KSRC/scripts/dtc/dtc nor a system dtc)" >&2
    exit 1
fi
echo "== compile (dtc = $DTC) =="
# An unknown -Wno-<check> is FATAL for dtc, and the check names differ between
# the distro dtc used here and the one Linux 7.2 builds, so probe them.
DTC_WFLAGS=$(sh "$REPO_ROOT/scripts/dtc-warn-flags.sh" "$DTC")
echo "   warning flags: ${DTC_WFLAGS:-(none)}"
# shellcheck disable=SC2086  # DTC_WFLAGS must word-split into separate flags
"$DTC" -o "$WORK/merged.dtb" -b 0 \
    -i "$KSRC/arch/arm64/boot/dts/qcom" \
    -i "$KSRC/scripts/dtc/include-prefixes" \
    $DTC_WFLAGS \
    "$WORK/merged.pre.dts"

test -s "$WORK/merged.dtb" || { echo "DTB not produced" >&2; exit 1; }
echo "   DTB size: $(wc -c < "$WORK/merged.dtb") bytes"

echo "== decode key nodes =="
"$DTC" -I dtb -O dts "$WORK/merged.dtb" 2>/dev/null > "$WORK/decoded.dts"

FAIL=0
check() {
    if grep -q "$1" "$WORK/decoded.dts"; then
        echo "  OK   $1"
    else
        echo "  MISS $1"
        FAIL=1
    fi
}
# Must NOT be in the tree (used by the lite-865 variant).
check_absent() {
    if grep -q "$1" "$WORK/decoded.dts"; then
        echo "  PRESENT (must not be): $1"
        FAIL=1
    else
        echo "  OK   absent: $1"
    fi
}

check 'qcom,sm8250-pinctrl'

if [ "$WITH_OVERLAY" = "0" ]; then
    # lite-865: the tree must not claim to be an EB5 and must not carry the
    # sequencer, otherwise the helper module would drive GPIO 82/88/... on a
    # board that has no ASM2806 behind PCIe1.
    check_absent 'thundercomm,eb5'
    check_absent 'thundercomm,tc-eb5-pcie-sequencer'
    check_absent 'pcie1-sequencer'
    if [ "$FAIL" = "1" ]; then
        echo "VALIDATION FAILED" >&2
        exit 1
    fi
    echo "ALL CHECKS PASSED"
    exit 0
fi

check 'pcie1-sequencer'
check 'thundercomm,tc-eb5-pcie-sequencer'
check 'thundercomm,eb5'
check 'pci_e1'
check 'iommu-map'
check 'asm2806-controls-default'
check 'lan1-pullup-state'

echo "== pcie1 node =="
awk '/pcie@1c08000 \{/,/^\t\t\};/' "$WORK/decoded.dts" \
    | grep -E 'status|num-lanes|perst-gpios|wake-gpios' || true

echo "== perst must resolve to the sequencer =="
seq_ph=$(awk '/pcie1-sequencer \{/,/^\t};/' "$WORK/decoded.dts" \
         | grep phandle | grep -oE '0x[0-9a-f]+' | head -1)
perst_ph=$(awk '/pcie@1c08000 \{/,/^\t\t\};/' "$WORK/decoded.dts" \
           | grep 'perst-gpios' | grep -oE '<0x[0-9a-f]+' | head -1 | tr -d '<')
if [ "$seq_ph" = "$perst_ph" ] && [ -n "$seq_ph" ]; then
    echo "  OK   perst -> sequencer (phandle $seq_ph)"
else
    echo "  FAIL perst phandle=$perst_ph != sequencer phandle=$seq_ph"
    FAIL=1
fi

if [ "$FAIL" = "1" ]; then
    echo "VALIDATION FAILED" >&2
    exit 1
fi
echo "ALL CHECKS PASSED"
