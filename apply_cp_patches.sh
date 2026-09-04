#!/usr/bin/env bash
# Apply (or preview) CircuitPython LVGL integration patches.
#
# Out-of-tree substitute for Adafruit Extending CircuitPython (no upstream PR):
#   Learn / design-guide step              This script
#   shared-bindings/<mod>/                 copy spike → CP shared-bindings/lvgl/
#   shared-module/<mod>/                   copy spike → CP shared-module/lvgl/
#   enable CIRCUITPY_* / mpconfig          CIRCUITPY_LVGL (+ GIFIO=0) in mk / h
#   list sources in port Makefile          board/variant SRC lists + SRC_PATTERNS
#   include port Makefile fragment         include circuitpython.mk from this repo
#   build CircuitPython                    caller runs make (or workspace build_cp.sh)
# Conceptual refs:
#   https://learn.adafruit.com/extending-circuitpython
#   https://docs.circuitpython.org/en/latest/docs/design_guide.html
#
# Usage:
#   ./apply_cp_patches.sh --apply --port PORT [--board BOARD] [--variant VARIANT]
#   ./apply_cp_patches.sh --force-apply --port PORT ...   # reinstall (user only)
#   ./apply_cp_patches.sh --dry-run --port PORT ...
#   ./apply_cp_patches.sh --status --port PORT ...
#
# Environment: WORKSPACE_DIR, CP_DIR, PORT, BOARD, VARIANT
#
# Standalone: clone circuitpython + lvgl-circuitpython (+ lvgl-bindings) as
# siblings, then:
#   ./apply_cp_patches.sh --apply --port unix --variant coverage
#   cd ../circuitpython/ports/unix && make -j VARIANT=coverage
# No other usermods required.
#
# All-port requirements (unix, espressif, …) — not ESP-specific:
#   1. include lvgl-circuitpython/circuitpython.mk from the port Makefile
#   2. SRC_QSTR excludes $(LV_CP_LVGL_SOURCES) (LVGL .c has no MP_QSTR_*; avoids ARG_MAX)
#   3. CIRCUITPY_GIFIO=0 when CIRCUITPY_LVGL=1 (lvgl-bindings lv_conf.h has LV_USE_GIF=1;
#      CircuitPython GIFIO vendors a colliding AnimatedGIF gif.c)
# No lvgl-bindings generator changes are required for those constraints.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

LV_CP_MOD_DIR=$(cd "$(dirname "$0")" && pwd)
WORKSPACE_DIR="${WORKSPACE_DIR:-$(cd "$LV_CP_MOD_DIR/.." && pwd)}"

# Resolve CircuitPython: CP_DIR, else sibling circuitpython/ under WORKSPACE_DIR.
if [[ -n "${CP_DIR:-}" && -d "${CP_DIR}/ports" ]]; then
    CP_DIR=$(cd "$CP_DIR" && pwd)
elif [[ -d "$WORKSPACE_DIR/circuitpython/ports" ]]; then
    CP_DIR=$(cd "$WORKSPACE_DIR/circuitpython" && pwd)
else
    die "CircuitPython tree not found (set CP_DIR, or place circuitpython/ next to this repo under $WORKSPACE_DIR)."
fi

PORT="${PORT:-}"
BOARD="${BOARD:-}"
VARIANT="${VARIANT:-}"
MODE=""
SPIKE_DIR="$LV_CP_MOD_DIR/src/circuitpython_spike"
SPIKE_MANIFEST="$SPIKE_DIR/copy_manifest.txt"

MARKER_TAG="lv-circuitpython-mod begin (apply_cp_patches.sh)"
MARKER_BEGIN="# >>> $MARKER_TAG"
MARKER_END="# >>> lv-circuitpython-mod end"

DRY_RUN=0
APPLY=0
FORCE=0
CONFIG_MKS=()
CONFIG_HS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|--apply|--force-apply|--status) MODE="$1"; shift ;;
        --port)    PORT="$2"; shift 2 ;;
        --board)   BOARD="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
done

MODE="${MODE:---dry-run}"
case "$MODE" in
    --dry-run) DRY_RUN=1 ;;
    --apply) APPLY=1 ;;
    --force-apply) APPLY=1; FORCE=1 ;;
    --status) ;;
    *) die "Unknown mode: $MODE" ;;
esac

log() { echo "$*"; }

markers_for_file() {
    local file="$1"
    case "$file" in
        *.h)
            echo "/* >>> $MARKER_TAG */"
            echo "/* >>> lv-circuitpython-mod end */"
            ;;
        *)
            echo "$MARKER_BEGIN"
            echo "$MARKER_END"
            ;;
    esac
}

repair_invalid_header_markers() {
    local file="$1"
    [ -f "$file" ] || return 0
    case "$file" in
        *.h) ;;
        *) return 0 ;;
    esac
    if ! grep -qF "# >>> lv-circuitpython-mod" "$file"; then
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "  [dry-run] repair invalid # markers in $file"
        return 0
    fi
    python3 - "$file" "$MARKER_TAG" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
tag = sys.argv[2]
text = path.read_text()
text = text.replace(f"# >>> {tag}", f"/* >>> {tag} */")
text = text.replace("# >>> lv-circuitpython-mod end", "/* >>> lv-circuitpython-mod end */")
path.write_text(text)
PY
    log "  repaired header markers: $file"
}

remove_marked_blocks() {
    local file="$1"
    local tag="$2"
    [ -f "$file" ] || return 0
    if ! grep -qF "$tag" "$file" 2>/dev/null; then
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "  [dry-run] remove marked blocks from $file"
        return 0
    fi
    python3 - "$file" "$tag" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
tag = re.escape(sys.argv[2])
text = path.read_text()
patterns = [
    rf"\n?# >>> {tag}\n.*?\n# >>> lv-circuitpython-mod end\n?",
    rf"\n?/\* >>> {tag} \*/\n.*?\n/\* >>> lv-circuitpython-mod end \*/\n?",
]
for pat in patterns:
    text = re.sub(pat, "\n", text, count=0, flags=re.DOTALL)
path.write_text(text)
PY
}

remove_current_patches() {
    remove_marked_blocks "$1" "$MARKER_TAG"
}

remove_raw_lvgl_lines() {
    local file="$1"
    [ -f "$file" ] || return 0
    if ! grep -qF 'lvgl/__init__.c' "$file" 2>/dev/null; then
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "  [dry-run] remove raw lvgl source lines from $file"
        return 0
    fi
    python3 - "$file" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = [
    line for line in path.read_text().splitlines(keepends=True)
    if "lvgl/__init__.c" not in line
]
path.write_text("".join(lines))
PY
    log "  removed raw lvgl source lines: $file"
}

patch_block_present() {
    local file="$1"
    local needle="${2:-lv-circuitpython-mod begin}"
    [ -f "$file" ] && grep -qF "$needle" "$file"
}

should_skip_patch() {
    local file="$1"
    local needle="${2:-lv-circuitpython-mod begin}"
    [ "$FORCE" = 0 ] && patch_block_present "$file" "$needle"
}

append_marked_block() {
    local file="$1"
    local block="$2"
    local needle="${3:-lv-circuitpython-mod begin}"
    repair_invalid_header_markers "$file"
    if should_skip_patch "$file" "$needle"; then
        log "  skip (already patched): $file"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "  [dry-run] append block to $file"
        return 0
    fi
    local begin end
    begin=$(markers_for_file "$file" | sed -n '1p')
    end=$(markers_for_file "$file" | sed -n '2p')
    python3 - "$file" "$begin" "$end" "$block" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
begin = sys.argv[2]
end = sys.argv[3]
block = sys.argv[4]

text = path.read_text()
if not text.endswith("\n"):
    text += "\n"
text += f"{begin}\n{block}\n{end}\n"
path.write_text(text)
PY
    log "  patched: $file"
}

insert_block_before_line() {
    local file="$1"
    local anchor="$2"
    local block="$3"
    local needle="${4:-lv-circuitpython-mod begin}"
    repair_invalid_header_markers "$file"
    if should_skip_patch "$file" "$needle"; then
        log "  skip (already patched): $file"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "  [dry-run] insert block into $file before: $anchor"
        return 0
    fi
    local begin end
    begin=$(markers_for_file "$file" | sed -n '1p')
    end=$(markers_for_file "$file" | sed -n '2p')
    python3 - "$file" "$anchor" "$begin" "$end" "$block" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
anchor = sys.argv[2]
begin = sys.argv[3]
end = sys.argv[4]
block = sys.argv[5]

text = path.read_text()
if begin in text:
    sys.exit(0)
if anchor not in text:
    raise SystemExit(f"anchor not found in {path}: {anchor!r}")
insert = f"\n{begin}\n{block}\n{end}\n"
path.write_text(text.replace(anchor, insert + anchor, 1))
PY
    log "  patched: $file"
}

insert_block_after_line() {
    local file="$1"
    local anchor="$2"
    local block="$3"
    local needle="${4:-lv-circuitpython-mod begin}"
    repair_invalid_header_markers "$file"
    if should_skip_patch "$file" "$needle"; then
        log "  skip (already patched): $file"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "  [dry-run] insert block into $file after: $anchor"
        return 0
    fi
    local begin end
    begin=$(markers_for_file "$file" | sed -n '1p')
    end=$(markers_for_file "$file" | sed -n '2p')
    python3 - "$file" "$anchor" "$begin" "$end" "$block" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
anchor = sys.argv[2]
begin = sys.argv[3]
end = sys.argv[4]
block = sys.argv[5]

text = path.read_text()
if begin in text:
    sys.exit(0)
if anchor not in text:
    raise SystemExit(f"anchor not found in {path}: {anchor!r}")
insert = f"\n{begin}\n{block}\n{end}\n"
path.write_text(text.replace(anchor, anchor + insert, 1))
PY
    log "  patched: $file"
}

insert_raw_after_line() {
    local file="$1"
    local anchor="$2"
    local line="$3"
    if [ "$FORCE" = 0 ] && grep -qF "$line" "$file" 2>/dev/null; then
        log "  skip (already present): $file"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "  [dry-run] insert into $file after: $anchor"
        return 0
    fi
    python3 - "$file" "$anchor" "$line" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
anchor = sys.argv[2]
line = sys.argv[3]

text = path.read_text()
if line in text:
    sys.exit(0)
if anchor not in text:
    raise SystemExit(f"anchor not found in {path}: {anchor!r}")
path.write_text(text.replace(anchor, anchor + "\n" + line, 1))
PY
    log "  patched: $file"
}

copy_spike_files() {
    python3 - "$SPIKE_DIR" "$CP_DIR" "$SPIKE_MANIFEST" "$DRY_RUN" <<'PY'
import filecmp
import shutil
import sys
from pathlib import Path

spike_dir, cp_dir, manifest, dry = sys.argv[1:5]
dry_run = dry == "1"

def copy_one(rel_dir: str, filename: str) -> None:
    rel = f"{rel_dir}/{filename}"
    src = Path(spike_dir)
    dst = Path(cp_dir)
    for part in rel_dir.split("/"):
        src /= part
        dst /= part
    src /= filename
    dst /= filename
    if not src.is_file():
        raise SystemExit(f"missing spike file: {src}")
    if dst.is_file() and filecmp.cmp(src, dst, shallow=False):
        print(f"  unchanged: {rel}")
        return
    if dry_run:
        verb = "update" if dst.is_file() else "create"
        print(f"  [dry-run] {verb} {rel}")
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    print(f"  copied: {rel}")

for raw in Path(manifest).read_text().splitlines():
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    rel_dir, filename = line.split("\t", 1)
    copy_one(rel_dir.strip(), filename.strip())
PY
}

resolve_config_files() {
    PORT_DIR="$CP_DIR/ports/$PORT"
    [[ -n "$PORT" ]] || die "PORT is required (--port or env)"
    [[ -f "$PORT_DIR/Makefile" ]] || die "Invalid port: $PORT"

    CONFIG_MKS=()
    CONFIG_HS=()

    if [[ -n "$BOARD" && -f "$PORT_DIR/boards/$BOARD/mpconfigboard.mk" ]]; then
        CONFIG_MKS+=("$PORT_DIR/boards/$BOARD/mpconfigboard.mk")
        [[ -f "$PORT_DIR/boards/$BOARD/mpconfigboard.h" ]] && \
            CONFIG_HS+=("$PORT_DIR/boards/$BOARD/mpconfigboard.h")
    fi

    local vdir=""
    if [[ -n "$BOARD" && -n "$VARIANT" && -f "$PORT_DIR/boards/$BOARD/variants/$VARIANT/mpconfigvariant.mk" ]]; then
        vdir="$PORT_DIR/boards/$BOARD/variants/$VARIANT"
    elif [[ -n "$VARIANT" && -f "$PORT_DIR/variants/$VARIANT/mpconfigvariant.mk" ]]; then
        vdir="$PORT_DIR/variants/$VARIANT"
    fi
    if [[ -n "$vdir" ]]; then
        CONFIG_MKS+=("$vdir/mpconfigvariant.mk")
        [[ -f "$vdir/mpconfigvariant.h" ]] && CONFIG_HS+=("$vdir/mpconfigvariant.h")
    fi

    [[ ${#CONFIG_MKS[@]} -gt 0 ]] || \
        die "No mpconfig makefiles for PORT=$PORT BOARD=${BOARD:-} VARIANT=${VARIANT:-}"
}

port_makefile_anchor() {
    if grep -qF 'include ../../py/mkenv.mk' "$PORT_MK"; then
        echo 'include ../../py/mkenv.mk'
    elif grep -qF 'include ../../py/circuitpy_mkenv.mk' "$PORT_MK"; then
        echo 'include ../../py/circuitpy_mkenv.mk'
    else
        die "No known mkenv include anchor in $PORT_MK"
    fi
}

patch_config_header() {
    local h="$1"
    local block="#ifndef CIRCUITPY_LVGL
#define CIRCUITPY_LVGL (0)
#endif"
    if grep -qF '#pragma once' "$h"; then
        insert_block_after_line "$h" '#pragma once' "$block"
    elif grep -qF '#include "../mpconfigvariant_common.h"' "$h"; then
        insert_block_after_line "$h" '#include "../mpconfigvariant_common.h"' "$block"
    else
        log "  skip header (no known anchor): $h"
    fi
}

patch_module_sources_if_present() {
    local mk="$1"
    if grep -qF 'shared-bindings/jpegio/JpegDecoder.c \' "$mk"; then
        insert_raw_after_line "$mk" $'shared-bindings/jpegio/JpegDecoder.c \\' \
            $'\tshared-bindings/lvgl/__init__.c \\'
        insert_raw_after_line "$mk" $'shared-module/jpegio/JpegDecoder.c \\' \
            $'\tshared-module/lvgl/__init__.c \\'
    else
        log "  skip module sources (no jpegio list in $mk)"
    fi
}

build_next_cmd() {
    # Standalone: plain make in the port directory.
    local port_dir="$CP_DIR/ports/$PORT"
    printf 'cd %q && make -j' "$port_dir"
    [[ -n "$BOARD" ]] && printf ' BOARD=%q' "$BOARD"
    [[ -n "$VARIANT" ]] && printf ' VARIANT=%q' "$VARIANT"
    printf '\n'
}

collect_patch_files() {
    ALL_PATCH_FILES=("$PORT_MK" "$MPCONFIG_MK" "$DEFNS_MK")
    ALL_PATCH_FILES+=("${CONFIG_MKS[@]}")
    ALL_PATCH_FILES+=("${CONFIG_HS[@]}")
}

# --- main ---

[ -d "$CP_DIR/ports" ] || die "CircuitPython tree not found at $CP_DIR (set CP_DIR)"
[ -f "$SPIKE_MANIFEST" ] || die "Missing spike manifest: $SPIKE_MANIFEST"

resolve_config_files

DEFNS_MK="$CP_DIR/py/circuitpy_defns.mk"
MPCONFIG_MK="$CP_DIR/py/circuitpy_mpconfig.mk"
PORT_MK="$PORT_DIR/Makefile"
LV_CP_MOD_REL=$(python3 -c "import os; print(os.path.relpath('$LV_CP_MOD_DIR', '$PORT_DIR'))")
collect_patch_files

log "CircuitPython: $CP_DIR"
log "workspace:     $WORKSPACE_DIR"
log "lvgl-circuitpython: $LV_CP_MOD_DIR (as $LV_CP_MOD_REL from port)"
log "port:            $PORT"
[[ -n "$BOARD" ]] && log "board:           $BOARD"
[[ -n "$VARIANT" ]] && log "variant:         $VARIANT"
log "mode:            $MODE"
log

if [ "$MODE" = "--status" ]; then
    SPIKE_INIT_C=$(python3 - "$SPIKE_MANIFEST" "$CP_DIR" <<'PY'
import sys
from pathlib import Path
manifest, cp_dir = sys.argv[1:3]
rel_dir, filename = Path(manifest).read_text().splitlines()[0].split("\t", 1)
p = Path(cp_dir)
for part in rel_dir.split("/"):
    p /= part
p /= filename.strip()
print(p)
PY
)
    report() {
        local label="$1"
        local file="$2"
        if [ ! -e "$file" ]; then
            echo "missing  $file"
        elif [ "$label" = "spike" ]; then
            echo "ok       $file"
        elif patch_block_present "$file"; then
            echo "patched  $file"
        else
            echo "pending  $file"
        fi
    }
    report spike "$SPIKE_INIT_C"
    for mk in "${CONFIG_MKS[@]}"; do report patch "$mk"; done
    for h in "${CONFIG_HS[@]}"; do report patch "$h"; done
    report patch "$DEFNS_MK"
    report patch "$MPCONFIG_MK"
    report patch "$PORT_MK"
    # All-port LVGL build contracts (see script header).
    if grep -qF 'circuitpython.mk' "$PORT_MK" 2>/dev/null && grep -qF 'LV_CP_MOD_DIR' "$PORT_MK" 2>/dev/null; then
        echo "ok       port Makefile includes circuitpython.mk"
    else
        echo "pending  port Makefile circuitpython.mk include"
    fi
    if grep -qF 'filter-out $(LV_CP_LVGL_SOURCES)' "$PORT_MK" 2>/dev/null; then
        echo "ok       port Makefile SRC_QSTR filters out LV_CP_LVGL_SOURCES"
    else
        echo "pending  port Makefile SRC_QSTR filter-out LV_CP_LVGL_SOURCES"
    fi
    if grep -qE 'CIRCUITPY_GIFIO[[:space:]]*=[[:space:]]*0' "$MPCONFIG_MK" 2>/dev/null \
        || { [[ ${#CONFIG_MKS[@]} -gt 0 ]] && grep -qE 'CIRCUITPY_GIFIO[[:space:]]*=[[:space:]]*0' "${CONFIG_MKS[@]}" 2>/dev/null; }; then
        echo "ok       CIRCUITPY_GIFIO=0 (mpconfig and/or board/variant)"
    else
        echo "pending  CIRCUITPY_GIFIO=0 when LVGL enabled"
    fi
    # JPEG decoder for LVGL: src/lv_jpegio_decoder_circuitpython.c (built via
    # circuitpython.mk, registered from the copied shared-module/lvgl/__init__.c;
    # active only when the port/variant defines CIRCUITPY_JPEGIO=1).
    if grep -qF 'lv_jpegio_decoder_circuitpython_init' "$CP_DIR/shared-module/lvgl/__init__.c" 2>/dev/null; then
        echo "ok       jpegio decoder shim present (shared-module/lvgl/__init__.c registers lib/tjpgd with LVGL)"
    else
        echo "pending  jpegio decoder shim hook in shared-module/lvgl/__init__.c (re-run --apply)"
    fi
    exit 0
fi

if [ "$FORCE" = 1 ]; then
    log "==> Remove existing LVGL patches (force reinstall)"
    for _f in "${ALL_PATCH_FILES[@]}"; do
        remove_current_patches "$_f"
        remove_raw_lvgl_lines "$_f"
    done
    log
fi

log "==> Copy spike templates"
copy_spike_files
log

# GIFIO's lib/AnimatedGIF/gif.c duplicates LVGL libs/gif/gif.c — keep LVGL's.
LVGL_ENABLE_BLOCK="CIRCUITPY_LVGL = 1
CIRCUITPY_GIFIO = 0
CFLAGS += -DCIRCUITPY_LVGL=1
CFLAGS += -DLVGL_GENERATED_PHASE1=1"

for mk in "${CONFIG_MKS[@]}"; do
    log "==> Patch $(basename "$(dirname "$mk")")/$(basename "$mk")"
    append_marked_block "$mk" "$LVGL_ENABLE_BLOCK"
    patch_module_sources_if_present "$mk"
    log
done

for h in "${CONFIG_HS[@]}"; do
    log "==> Patch $(basename "$h")"
    patch_config_header "$h"
    log
done

log "==> Patch py/circuitpy_mpconfig.mk (default off; GIFIO off when LVGL on)"
# CIRCUITPY_GIFIO ?= $(CIRCUITPY_DISPLAYIO) earlier in this file — force off when LVGL
# links libs/gif (lvgl-bindings lv_conf.h: LV_USE_GIF=1).
MPCONFIG_BLOCK="CIRCUITPY_LVGL ?= 0
CFLAGS += -DCIRCUITPY_LVGL=\$(CIRCUITPY_LVGL)
ifeq (\$(CIRCUITPY_LVGL),1)
CIRCUITPY_GIFIO = 0
endif"
# Refresh marked block content if an older LVGL-only block is present (no force-apply).
if [ "$DRY_RUN" = 1 ]; then
    if grep -qF "$MARKER_TAG" "$MPCONFIG_MK" 2>/dev/null \
        && ! grep -qE 'CIRCUITPY_GIFIO[[:space:]]*=[[:space:]]*0' "$MPCONFIG_MK" 2>/dev/null; then
        echo "  [dry-run] would refresh mpconfig LVGL block to force CIRCUITPY_GIFIO=0"
    fi
elif grep -qF "$MARKER_TAG" "$MPCONFIG_MK" 2>/dev/null; then
    python3 - "$MPCONFIG_MK" "$MARKER_BEGIN" "$MARKER_END" "$MPCONFIG_BLOCK" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
begin, end, block = sys.argv[2], sys.argv[3], sys.argv[4]
text = path.read_text()
start = text.find(begin)
stop = text.find(end, start)
if start < 0 or stop < 0:
    raise SystemExit(f"marked block not found in {path}")
stop += len(end)
new = text[:start] + f"{begin}\n{block}\n{end}" + text[stop:]
if new != text:
    path.write_text(new)
    print(f"  refreshed: {path}")
else:
    print(f"  skip (mpconfig LVGL block current): {path}")
PY
else
    insert_block_after_line "$MPCONFIG_MK" "CFLAGS += -DCIRCUITPY_LOCALE=\$(CIRCUITPY_LOCALE)" "$MPCONFIG_BLOCK"
fi
log

log "==> Patch py/circuitpy_defns.mk"
DEFNS_PATTERNS_BLOCK="ifeq (\$(CIRCUITPY_LVGL),1)
SRC_PATTERNS += lvgl/%
endif"
insert_block_before_line "$DEFNS_MK" "ifeq (\$(CIRCUITPY_MATH),1)" "$DEFNS_PATTERNS_BLOCK" "SRC_PATTERNS += lvgl/%"
insert_raw_after_line "$DEFNS_MK" $'\tjpegio/JpegDecoder.c \\' $'\tlvgl/__init__.c \\'
log

log "==> Patch port Makefile (circuitpython.mk)"
PORT_BLOCK="LV_CP_MOD_DIR := \$(abspath $LV_CP_MOD_REL)
include \$(LV_CP_MOD_DIR)/circuitpython.mk"
insert_block_after_line "$PORT_MK" "$(port_makefile_anchor)" "$PORT_BLOCK"
log

# Exclude LVGL core .c from SRC_QSTR on every port (no MP_QSTR_* in upstream LVGL).
# Required for ESP ARG_MAX; correct and cheap on unix and others too.
log "==> Patch port Makefile (SRC_QSTR filter-out LVGL)"
if [ "$DRY_RUN" = 1 ]; then
    if grep -qE '^SRC_QSTR \+= \$\{?SRC_C\}?' "$PORT_MK" \
        && ! grep -q 'filter-out \$(LV_CP_LVGL_SOURCES)' "$PORT_MK"; then
        echo "  [dry-run] would rewrite SRC_QSTR += \$(SRC_C) ... to filter-out LV_CP_LVGL_SOURCES"
    elif grep -q 'filter-out \$(LV_CP_LVGL_SOURCES)' "$PORT_MK"; then
        echo "  skip (already patched): $PORT_MK"
    else
        echo "  [dry-run] ERROR: no SRC_QSTR += \$(SRC_C) line in $PORT_MK"
    fi
else
    python3 - "$PORT_MK" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
if "filter-out $(LV_CP_LVGL_SOURCES)" in text:
    print(f"  skip (already patched): {path}")
    raise SystemExit(0)
# Match: SRC_QSTR += $(SRC_C) ...   or SRC_QSTR += ${SRC_C} ...
pat = re.compile(
    r"^(SRC_QSTR \+= )\$(\(|\{)SRC_C(\)|\})(.*)$",
    re.M,
)
repl = r"\1$(filter-out $(LV_CP_LVGL_SOURCES),$(SRC_C))\4"
new, n = pat.subn(repl, text, count=1)
if n == 0:
    print(
        f"error: no SRC_QSTR += $(SRC_C) line in {path}; "
        "all-port LVGL apply requires this for qstr filter-out",
        file=sys.stderr,
    )
    raise SystemExit(1)
path.write_text(new)
print(f"  patched: {path}")
PY
fi
log

# Full LVGL app is ~2.7MB; stock esp-idf-config/partitions-16MB.csv ota_0 is only 2048K.
# Install a 4096K ota_0 table and point the board sdkconfig at it (must live under
# esp-idf-config/ — relative paths outside the port tree are ignored by IDF confgen).
if [[ "$PORT" == espressif && -n "$BOARD" ]]; then
    board_mk="$PORT_DIR/boards/$BOARD/mpconfigboard.mk"
    board_sdk="$PORT_DIR/boards/$BOARD/sdkconfig"
    src_csv="$LV_CP_MOD_DIR/scripts/partitions-16MB-lvgl.csv"
    dst_csv="$PORT_DIR/esp-idf-config/partitions-16MB-lvgl.csv"
    if [[ -f "$board_mk" ]] && grep -qE 'CIRCUITPY_ESP_FLASH_SIZE[[:space:]]*=[[:space:]]*16MB' "$board_mk"; then
        log "==> Install 16MB LVGL partition table for $BOARD"
        if [[ ! -f "$src_csv" ]]; then
            die "Missing $src_csv"
        fi
        if [ "$DRY_RUN" = 1 ]; then
            echo "  [dry-run] would copy $src_csv -> $dst_csv"
            echo "  [dry-run] would write $board_sdk (partitions-16MB-lvgl.csv)"
        else
            cp "$src_csv" "$dst_csv"
            cat > "$board_sdk" <<'EOF'
#
# Larger app partition for CircuitPython + LVGL (~2.7MB+).
# Stock partitions-16MB.csv ota_0 is 2048K — too small.
#
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="esp-idf-config/partitions-16MB-lvgl.csv"
CONFIG_PARTITION_TABLE_FILENAME="esp-idf-config/partitions-16MB-lvgl.csv"
EOF
            echo "  wrote: $dst_csv"
            echo "  wrote: $board_sdk"
        fi
        log
    fi
fi

if [ "$DRY_RUN" = 1 ]; then
    log "Dry run complete. Re-run with --apply to write changes."
elif [ "$APPLY" = 1 ]; then
    log "Patches applied."
    log
    log "Next:"
    log "  $(build_next_cmd)"
    log "The org's optional aggregator workspace (https://github.com/PyDevices/cmods) offers an easier way to build with other extensions."
fi

exit 0
