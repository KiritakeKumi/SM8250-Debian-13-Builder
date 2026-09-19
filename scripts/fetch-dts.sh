#!/usr/bin/env bash
# Resolve the board device tree into $WORKSPACE/dts/.
#
# Sources:
#   upstream-armbian   - the Armbian-maintained mainline DT for this board
#                        (qcs8250-dg-svr-865-tiny.dts), pulled from armbian/build.
#                        It is saved locally as <DTS_FILE>.dts.
#   upstream-vendor-dg - the in-repo snapshot dts/<DTS_FILE>.dts (offline, reproducible).
#   custom             - whatever the user dropped into dts/custom/.
set -euo pipefail

: "${WORKSPACE:?WORKSPACE not set}"
: "${DTB_SOURCE:?DTB_SOURCE not set}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/config/image.conf"

OUT="$WORKSPACE/dts"
mkdir -p "$OUT"
DTS_NAME="${DTS_FILE}.dts"

case "$DTB_SOURCE" in
    upstream-armbian)
        echo "fetching upstream DT -> $DTS_NAME"
        if ! curl -fL --retry 5 --retry-delay 5 -o "$OUT/$DTS_NAME" "$UPSTREAM_DTS_URL"; then
            echo "primary URL failed, trying fallback"
            curl -fL --retry 5 --retry-delay 5 -o "$OUT/$DTS_NAME" "$UPSTREAM_DTS_URL_FALLBACK"
        fi
        ;;
    upstream-vendor-dg)
        echo "using in-repo $DTS_NAME"
        cp -v "$REPO_ROOT/dts/$DTS_NAME" "$OUT/$DTS_NAME"
        ;;
    custom)
        echo "using custom device tree from dts/custom/"
        shopt -s nullglob
        files=("$REPO_ROOT"/dts/custom/*.dts "$REPO_ROOT"/dts/custom/*.dtsi)
        shopt -u nullglob
        if [[ ${#files[@]} -eq 0 ]]; then
            echo "ERROR: dtb_source=custom but dts/custom/ has no .dts/.dtsi files" >&2
            exit 1
        fi
        cp -v "${files[@]}" "$OUT/"
        if [[ ! -f "$OUT/$DTS_NAME" ]]; then
            echo "ERROR: dts/custom/ must contain a file named $DTS_NAME" >&2
            exit 1
        fi
        ;;
    *)
        echo "ERROR: unknown DTB_SOURCE '$DTB_SOURCE'" >&2
        exit 1
        ;;
esac

test -s "$OUT/$DTS_NAME" || { echo "ERROR: $OUT/$DTS_NAME is missing or empty" >&2; exit 1; }

echo "device tree source:"
ls -l "$OUT"
echo "---- first 25 lines of $DTS_NAME ----"
head -25 "$OUT/$DTS_NAME"

echo "$DTS_NAME" > "$WORKSPACE/dts-name.txt"
echo "$IMAGE_NAME" > "$WORKSPACE/image-name.txt"
