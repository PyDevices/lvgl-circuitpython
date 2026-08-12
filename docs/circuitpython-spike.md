# CircuitPython spike templates

Target board: **[ESP32-P4-Function-EV-Board](https://circuitpython.org/board/espressif_esp32p4_function_ev/)**
(`BOARD=espressif_esp32p4_function_ev`, `ports/espressif`).

These templates match Adafruit’s
[Extending CircuitPython](https://learn.adafruit.com/extending-circuitpython)
`shared-bindings` / `shared-module` layout, but live in this repo instead of
being committed upstream. Copy them into a CircuitPython tree after
`circuitpython/` is in place. Use `apply_cp_patches.sh` for `CIRCUITPY_LVGL`,
`circuitpy_defns.mk`, and `circuitpython.mk` wiring (see the README Learn-guide
mapping table).

## Layout in CircuitPython

```
circuitpython/
  shared-bindings/lvgl/__init__.c   ← from src/circuitpython_spike/
  shared-bindings/lvgl/__init__.h
  shared-module/lvgl/__init.c
  shared-module/lvgl/__init.h
```

Generated bindings (not copied wholesale):

```
lvgl-bindings/generated/lvgl_circuitpython.c   ← regenerate_lvcp.sh
```

## Build flow

1. Apply CP tree patches (dry-run first):

```bash
./apply_cp_patches.sh --dry-run
./apply_cp_patches.sh --apply
```

Spike files to copy are listed in `src/circuitpython_spike/copy_manifest.txt`.

2. `CIRCUITPY_LVGL=1` on the target board or unix variant (patch script adds this).
3. Port `Makefile` includes `$(LV_CP_MOD_DIR)/circuitpython.mk` (patch script adds this).

Display flush/tick: **ON HOLD** — not in these C files. See the binding
[GC and callback lifetime audit](https://github.com/PyDevices/lvgl-bindings/blob/main/docs/gc-callback-audit.md).

## Merging generated bindings into the spike module

Full emission (`max_phase: 7` in `lvgl-bindings`) produces
`generated/lvgl_circuitpython.c` (~39.5k lines, parity with
`lvgl_micropython.c`) containing:

- Constants, blobs, enums, structs (with methods), widget types, module functions, callbacks
- A mergeable tail: `LVCP_MODULE_GLOBALS` macro plus `lvgl_module_entries[]`

The hand-written spike keeps `init` / `deinit` / `__version__`. Generated symbols
are **not** registered via `MP_REGISTER_MODULE` in the generated TU; they are
spliced into the spike dict.

### Step A — compile generated C

`circuitpython.mk` adds `$(LV_BINDINGS_DIR)/generated/lvgl_circuitpython.c` to
the port build. Blob/string object definitions must be linked before the spike
module references them.

### Step B — expand the globals table

In `shared-bindings/lvgl/__init__.c`, when `LVGL_GENERATED_PHASE1` is defined:

```c
#ifdef LVGL_GENERATED_PHASE1
extern const mp_rom_map_elem_t lvgl_module_entries[];
extern const size_t lvgl_module_entry_count;
#endif

static const mp_rom_map_elem_t lvgl_module_globals_table[] = {
    { MP_ROM_QSTR(MP_QSTR___name__), MP_ROM_QSTR(MP_QSTR_lvgl) },
    { MP_ROM_QSTR(MP_QSTR___version__), MP_ROM_QSTR(MP_QSTR_9) },
    { MP_ROM_QSTR(MP_QSTR_init), MP_ROM_PTR(&lvgl_init_obj) },
    { MP_ROM_QSTR(MP_QSTR_deinit), MP_ROM_PTR(&lvgl_deinit_obj) },
#ifdef LVGL_GENERATED_PHASE1
    LVCP_MODULE_GLOBALS
#endif
};
```

Re-run `regenerate_lvcp.sh` after LVGL header changes.

### What remains outside generated C

- `MP_REGISTER_MODULE` — the spike module owns registration
- Display flush/tick — **ON HOLD** (Python bridge; resume when requested)

## Open questions

1. **Single TU vs split:** One generated TU is simplest; split only if compile time hurts.
2. **ROM budget:** Full API may exceed smaller boards — trim via metadata /
   `CIRCUITPY_LVGL_FULL` later (see `docs/circuitpython-flash-budget.md`).
3. **GC roots:** Python callbacks stored only in LVGL `user_data` — see the
   binding [GC audit](https://github.com/PyDevices/lvgl-bindings/blob/main/docs/gc-callback-audit.md).
4. **Display bridge:** **ON HOLD**.
5. **Type checking:** Keep MP-style `mp_to_lv` validation or adopt CP
   `mp_arg_validate` where available.
