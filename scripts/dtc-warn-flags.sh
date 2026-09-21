#!/bin/sh
# Print the subset of our preferred dtc "-Wno-<check>" flags that the given dtc
# binary actually understands, space separated, on one line.
#
# Why this is not just a hardcoded list:
#
# dtc check names are not stable across versions, and an unknown one is FATAL,
# not a warning. The dtc bundled with Linux 7.2 no longer knows
# graph_child_address, so the flag list that worked on 6.18 killed the build:
#
#     compiling nico-debian-sm8250.dtb
#     FATAL ERROR: Unrecognized check name "graph_child_address"
#
# It also cannot be worked around by picking one dtc: the validate job uses the
# distro dtc (the kernel tree is a sparse checkout with nothing built), while
# build-kernel.sh uses $KDIR/scripts/dtc/dtc from the tree it just built. The
# two know different check names.
#
# These flags only silence warnings, so dropping an unsupported one is safe --
# the DTB is identical either way.
#
# Usage: scripts/dtc-warn-flags.sh <path-to-dtc>
set -eu

DTC="${1:-}"
[ -n "$DTC" ] || { echo "usage: $0 <path-to-dtc>" >&2; exit 2; }

# The warnings this board's DTS legitimately trips. Order is preserved in the
# output so the compile command reads the same way it always did.
CHECKS="unique_unit_address
unit_address_vs_reg
avoid_unnecessary_addr_size
alias_paths
graph_child_address
simple_bus_reg"

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
printf '/dts-v1/;\n/ { };\n' > "$PROBE/probe.dts"

flags=
for c in $CHECKS; do
    if "$DTC" "-Wno-$c" -I dts -O dtb -o "$PROBE/probe.dtb" "$PROBE/probe.dts" \
         >/dev/null 2>&1; then
        flags="$flags -Wno-$c"
    else
        echo "   note: this dtc does not know the '$c' check; dropping -Wno-$c" >&2
    fi
done

# strip the leading space; an empty list prints an empty line, which the
# callers expand to nothing
printf '%s\n' "${flags# }"
