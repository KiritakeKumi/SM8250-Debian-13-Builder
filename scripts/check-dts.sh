#!/bin/sh
# Validate the DTS + overlay by preprocessing and compiling it, using the
# actual kernel source tree (needed for sm8250.dtsi and dt-bindings).
#
# Usage: scripts/check-dts.sh <path-to-linux-source>
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
KSRC="${1:-}"
if [ -z "$KSRC" ] || [ ! -f "$KSRC/Makefile" ]; then
    echo "usage: $0 <path-to-linux-source-tree>" >&2
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
cat "$REPO_ROOT/dts/${DTS_FILE}.dts" \
    "$REPO_ROOT/dts/patches/nic-fix-overlay.dtsi" > "$WORK/merged.dts"
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
"$DTC" -o "$WORK/merged.dtb" -b 0 \
    -i "$KSRC/arch/arm64/boot/dts/qcom" \
    -i "$KSRC/scripts/dtc/include-prefixes" \
    -Wno-unique_unit_address -Wno-unit_address_vs_reg -Wno-avoid_unnecessary_addr_size \
    -Wno-alias_paths -Wno-graph_child_address -Wno-simple_bus_reg \
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
check 'pcie1-sequencer'
check 'thundercomm,tc-eb5-pcie-sequencer'
check 'qcom,sm8250-pinctrl'
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
