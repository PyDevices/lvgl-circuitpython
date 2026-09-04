#!/usr/bin/env bash
# Host proof of src/lv_jpegio_decoder_circuitpython.c without a CircuitPython build.
#
# Links LVGL (the sibling lvgl-bindings checkout at the pin in
# LVGL_BINDINGS_COMMIT, with its CircuitPython lv_conf.h) + CircuitPython's
# lib/tjpgd/src/tjpgd.c + the shim + a malloc twin of the CP allocator and GC
# roots, then renders every jpegio corpus frame through lv_image onto a
# 320x240 native-RGB565 display (variable source with a zeroed header, and file
# source through a stdio lv_fs driver) and compares the flushed pixels against
# jpegio's golden digests (displayif tests/jpegio/frames/golden_tjpgd.json,
# scale 0). Frames the golden file knows must decode and match; the others
# (progressive, DHT-less) must be refused. Also proves: exactly one jd_prepare
# in the link (CP's), registration is idempotent, and re-arms after lv_deinit.
#
#   ./tools/host_jpegio_decoder_check.sh
#
# Environment: LV_BINDINGS_DIR (default ../lvgl-bindings), CP_DIR (default
# ../circuitpython, else ../cmods/circuitpython), JPEGIO_FRAMES (default
# ../displayif/tests/jpegio/frames). The CP tree is only read (headers and one
# .c compiled into tools/host_jpegio_decoder_check/build/). Needs gcc, python3.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
WS=$(cd "$ROOT/.." && pwd)
B=${LV_BINDINGS_DIR:-$WS/lvgl-bindings}
CP=${CP_DIR:-}
if [[ -z "$CP" ]]; then
    for c in "$WS/circuitpython" "$WS/cmods/circuitpython"; do
        [[ -f "$c/lib/tjpgd/src/tjpgd.c" ]] && CP=$c && break
    done
fi
FRAMES=${JPEGIO_FRAMES:-$WS/displayif/tests/jpegio/frames}
SRC=$HERE/host_jpegio_decoder_check
BUILD=$SRC/build
SHIM=${SHIM:-$ROOT/src/lv_jpegio_decoder_circuitpython.c}

[[ -f "$B/lvgl/lvgl.h" ]] || { echo "error: lvgl-bindings not at $B (set LV_BINDINGS_DIR)" >&2; exit 1; }
[[ -n "$CP" && -f "$CP/lib/tjpgd/src/tjpgd.c" ]] || { echo "error: CircuitPython tree with lib/tjpgd not found (set CP_DIR)" >&2; exit 1; }
[[ -f "$FRAMES/golden_tjpgd.json" ]] || { echo "error: jpegio corpus not at $FRAMES (set JPEGIO_FRAMES)" >&2; exit 1; }

PIN=$(tr -d '[:space:]' < "$ROOT/LVGL_BINDINGS_COMMIT")
if ! git -C "$B" cat-file -e "$PIN^{commit}" 2>/dev/null || ! git -C "$B" diff --quiet "$PIN" -- lvgl lv_conf.h || ! git -C "$B" diff --quiet -- lvgl lv_conf.h; then
    echo "error: $B does not match pinned binding inputs $PIN (lvgl, lv_conf.h)" >&2
    exit 1
fi

echo "lvgl-bindings: $B @ $(git -C "$B" rev-parse --short HEAD) (pin $PIN)"
echo "circuitpython: $CP (lib/tjpgd)"
echo "corpus:        $FRAMES"
echo "shim:          $SHIM"

mkdir -p "$BUILD/lvgl"
COMMON="-std=gnu99 -O1 -g -DLV_CIRCUITPYTHON_BUILD=1 -DMICROPY_LV_USE_LOG=1 -I$B -I$B/lvgl -I$CP"

STAMP="$BUILD/lvgl/.stamp"
WANT="$(git -C "$B" rev-parse HEAD) $(sha256sum "$B/lv_conf.h" | cut -c1-16)"
if [[ ! -f "$STAMP" || "$(cat "$STAMP")" != "$WANT" ]]; then
    echo "== compiling LVGL src/*.c (bindings pin, CircuitPython lv_conf.h)"
    rm -rf "$BUILD/lvgl"; mkdir -p "$BUILD/lvgl"
    find "$B/lvgl/src" -name '*.c' | sort > "$BUILD/lvgl.list"
    export B BUILD COMMON
    xargs -a "$BUILD/lvgl.list" -P"$(nproc)" -I{} sh -c 'rel="${1#$B/lvgl/}"; o="$BUILD/lvgl/${rel%.c}.o"; mkdir -p "$(dirname "$o")"; exec gcc $COMMON -w -c "$1" -o "$o"' _ {}
    echo "$WANT" > "$STAMP"
fi

echo "== CircuitPython lib/tjpgd/src/tjpgd.c (its own CP flags: -Wno-shadow -Wno-cast-align)"
gcc -std=gnu99 -O1 -g -Wall -Werror -Wno-shadow -Wno-cast-align -I"$CP" -c "$CP/lib/tjpgd/src/tjpgd.c" -o "$BUILD/tjpgd.o"
echo "== shim under the CP unix coverage warning set, no suppressions"
gcc $COMMON -Wall -Werror -Wextra -Wno-unused-parameter -Wpointer-arith -Wdouble-promotion -Wfloat-conversion -Wno-missing-field-initializers \
    -Wformat -Wmissing-declarations -Wmissing-prototypes -Wold-style-definition -Wshadow -Wuninitialized -Wunused-parameter \
    -DCIRCUITPY_JPEGIO=1 -c "$SHIM" -o "$BUILD/shim.o"
echo "== host allocator/roots twin + harness, link"
gcc $COMMON -Wall -Werror -c "$SRC/lv_mem_core_host.c" -o "$BUILD/mem.o"
gcc $COMMON -Wall -Werror -Wextra -Wno-unused-parameter -c "$SRC/host_check.c" -o "$BUILD/main.o"
mapfile -t LVOBJS < <(find "$BUILD/lvgl" -name '*.o' | sort)
gcc -o "$BUILD/host_check" "$BUILD/main.o" "$BUILD/shim.o" "$BUILD/mem.o" "$BUILD/tjpgd.o" "${LVOBJS[@]}" -lm

echo "== symbols: objects defining jd_prepare (must be exactly one, CP's), and no lv_tjpgd_init"
n=0
for o in "$BUILD/tjpgd.o" "${LVOBJS[@]}"; do
    if nm "$o" | grep -q ' T jd_prepare$'; then echo "  ${o#$BUILD/}"; n=$((n + 1)); fi
done
[[ $n -eq 1 ]] || { echo "error: $n objects define jd_prepare" >&2; exit 1; }
if nm "$BUILD/host_check" | grep -q ' T lv_tjpgd_init$'; then echo "error: lv_tjpgd_init is linked (LV_USE_TJPGD is not 0)" >&2; exit 1; fi

OUT="$BUILD/out"
rm -rf "$OUT"; mkdir -p "$OUT"
mapfile -t JPGS < <(find "$FRAMES" -maxdepth 1 -name '*.jpg' | sort)
echo "== decode ${#JPGS[@]} frames through lv_image (LVGL warnings go to $OUT/lvgl.log)"
set +e
"$BUILD/host_check" "$OUT" "${JPGS[@]}" 2> "$OUT/lvgl.log"
rc=$?
set -e
echo "harness exit $rc"

echo "== digests vs $FRAMES/golden_tjpgd.json (scale 0)"
python3 - "$OUT" "$FRAMES/golden_tjpgd.json" "$rc" <<'PY'
import hashlib, json, os, sys
out, golden_path, rc = sys.argv[1], sys.argv[2], int(sys.argv[3])
golden = json.load(open(golden_path))["frames"]
files = sorted(f for f in os.listdir(out) if f.endswith(".rgb565"))
seen = {}
bad = 0
for fn in files:
    mode, name = fn.split("_", 1)
    name = name[: -len(".rgb565")]
    digest = hashlib.sha256(open(os.path.join(out, fn), "rb").read()).hexdigest()
    want = golden.get(name, {}).get("0")
    if want is None:
        status = "DECODED BUT NOT IN GOLDEN (should have been refused)"
        bad += 1
    elif digest == want:
        status = "match"
    else:
        status = "MISMATCH (golden %s..)" % want[:16]
        bad += 1
    seen.setdefault(name, set()).add(mode)
    print("  %-5s %-36s %s.. %s" % (mode, name, digest[:16], status))
for name in sorted(golden):
    for mode in ("var", "file"):
        if mode not in seen.get(name, ()):
            print("  %-5s %-36s MISSING: golden frame was not rendered" % (mode, name))
            bad += 1
print("frames in golden: %d; rendered outputs: %d; problems: %d" % (len(golden), len(files), bad))
sys.exit(1 if bad or rc else 0)
PY
echo "host jpegio decoder check passed"
