#!/bin/sh
# Validate the DTS + overlay by preprocessing and compiling it, using the
# actual kernel tree if one is present.
#
# Usage: scripts/check-dts.sh [path-to-linux-source]
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
KSRC="${1:-}"
if [ -z "$KSRC" ] || [ ! -f "$KSRC/Makefile" ]; then
    echo "usage: $0 <path-to-linux-source-tree>" >&2
    echo "(a full kernel source tree is needed for sm8250.dtsi and dt-bindings)" >&2
    exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat "$REPO_ROOT/dts/qcs8250-nico-debian-sm8250.dts" \
    "$REPO_ROOT/dts/patches/nic-fix-overlay.dtsi" > "$WORK/merged.dts"

echo "== preprocess =="
gcc -E -nostdinc \
    -I "$KSRC/scripts/dtc/include-prefixes" \
    -I "$KSRC/arch/arm64/boot/dts/qcom" \
    -I "$KSRC/arch/arm64/boot/dts" \
    -I "$KSRC/include" \
    -undef -D__DTS__ -x assembler-with-cpp \
    -o "$WORK/merged.pre.dts" "$WORK/merged.dts"

echo "== compile =="
"$KSRC/scripts/dtc/dtc" -o "$WORK/merged.dtb" -b 0 \
    -i "$KSRC/arch/arm64/boot/dts/qcom" \
    -i "$KSRC/scripts/dtc/include-prefixes" \
    -Wno-unique_unit_address -Wno-unit_address_vs_reg -Wno-avoid_unnecessary_addr_size \
    -Wno-alias_paths -Wno-graph_child_address -Wno-simple_bus_reg \
    "$WORK/merged.pre.dts"

echo "== decode key nodes =="
dtc -I dtb -O dts "$WORK/merged.dtb" 2>/dev/null > "$WORK/decoded.dts"

check() {
    if grep -q "$1" "$WORK/decoded.dts"; then
        echo "  OK   $1"
    else
        echo "  MISS $1"
        FAIL=1
    fi
}
FAIL=0
check 'pcie1-sequencer'
check 'thundercomm,tc-eb5-pcie-sequencer'
check 'qcom,sm8250-pinctrl'
check 'pci_e1'
check 'iommu-map'
check 'asm2806-controls-default'
check 'lan1-pullup-state'

echo "== pcie1 status =="
awk '/pcie@1c08000 \{/,/^\t\t\};/' "$WORK/decoded.dts" | grep -E 'status|num-lanes|perst-gpios|wake-gpios' || true

if [ "$FAIL" = "1" ]; then
    echo "FAILED" >&2
    exit 1
fi
echo "all checks passed"
