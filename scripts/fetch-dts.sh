#!/usr/bin/env bash
# Resolve the board device tree into $WORKSPACE/dts/.
#
# Sources:
#   upstream-armbian   - the Armbian-maintained mainline DT for this board.
#                        Armbian only carries it in the sm8250-6.12 and
#                        sm8250-6.18 patch directories; there is no 6.19/7.x
#                        copy. If the download fails we fall back to the
#                        in-repo snapshot (verified to compile against 7.2).
#   upstream-vendor-dg - the in-repo snapshot dts/<DTS_FILE>.dts (offline).
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
SNAPSHOT="$REPO_ROOT/dts/$DTS_NAME"

copy_snapshot() {
    if [[ ! -s "$SNAPSHOT" ]]; then
        echo "ERROR: in-repo snapshot $SNAPSHOT is missing" >&2
        return 1
    fi
    cp -v "$SNAPSHOT" "$OUT/$DTS_NAME"
}

case "$DTB_SOURCE" in
    upstream-armbian)
        echo "fetching upstream DT -> $DTS_NAME"
        got=0
        for url in "$UPSTREAM_DTS_URL" "$UPSTREAM_DTS_URL_FALLBACK"; do
            echo "  trying $url"
            if curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 \
                    -o "$OUT/$DTS_NAME" "$url"; then
                if [[ -s "$OUT/$DTS_NAME" ]]; then
                    got=1
                    break
                fi
            fi
            rm -f "$OUT/$DTS_NAME"
        done
        if (( ! got )); then
            # Armbian has no 7.x copy of this DT; use our snapshot instead.
            # It is the same content and is verified against 7.2 headers.
            echo "  upstream download unavailable; using in-repo snapshot"
            if [[ "${FALLBACK_TO_REPO_SNAPSHOT:-true}" == "true" ]]; then
                copy_snapshot
            else
                echo "ERROR: could not fetch the upstream DT and the snapshot" >&2
                echo "       fallback is disabled (FALLBACK_TO_REPO_SNAPSHOT=false)" >&2
                exit 1
            fi
        fi
        ;;
    upstream-vendor-dg)
        echo "using in-repo $DTS_NAME"
        copy_snapshot
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
