# Newcomer's guide to lvgl-circuitpython

`lvgl-circuitpython` integrates PyDevices' generated LVGL bindings into a CircuitPython firmware build. It supplies the out-of-tree patch and build glue, a GC-aware LVGL allocator, synced Python helpers, and a CircuitPython-specific JPEG decoder.

It is not a pip package and does not generate the bindings. Work with sibling clones of [lvgl-bindings](https://github.com/PyDevices/lvgl-bindings) and [CircuitPython](https://github.com/adafruit/circuitpython); this repository consumes the exact bindings revision recorded in `LVGL_BINDINGS_COMMIT`.

## First use: the firmware application

After building firmware that includes this integration, initialize the display helper before importing and using LVGL:

```python
import display_driver  # initializes display and input
import lvgl as lv
from display_driver import app

screen = lv.screen_active()
label = lv.label(screen)
label.set_text("Hello CircuitPython LVGL!")
label.center()

app.run()
```

CircuitPython has no `machine.Timer` or signal FFI for this role. `display_driver` and `multimer` use a cooperative event loop, so an application runs `app.run()` (or its own `asyncio` loop) to pump LVGL tasks and input events.

## The mental model

```text
lvgl-bindings at the pinned generated revision
                  |
                  v
lvgl-circuitpython patch + build glue
                  |
                  +--> CircuitPython shared-bindings/shared-module/lvgl
                  +--> generated C source/header + allocator
                  +--> frozen display_driver and fs_driver
                  |
                  v
CircuitPython firmware: import display_driver, then import lvgl
```

The generated source, header, LVGL pin, and configuration must all match the recorded bindings commit. Change generator-owned code and the synced Python helpers in `lvgl-bindings`, then regenerate and synchronize; do not edit their copied forms here.

## Repository map

| Path | Role |
|---|---|
| `apply_cp_patches.sh` | Applies or previews the out-of-tree integration in a CircuitPython clone. |
| `circuitpython.mk` | Port Makefile fragment for generated bindings, LVGL, and allocator sources. |
| `src/circuitpython_spike/` | Hand-written `shared-bindings/lvgl` and `shared-module/lvgl` templates copied into CircuitPython. |
| `src/lv_mem_core_circuitpython.c` | GC-aware LVGL allocator. |
| `src/lv_jpegio_decoder_circuitpython.c` | LVGL decoder backed by CircuitPython's `jpegio`/TJpgDec support. |
| `lib/display_driver.py`, `lib/fs_driver.py` | Synced helpers frozen by `manifest.py`. |
| `scripts/sync_from_lvgl_bindings.sh` | Refreshes synced helpers from an exact bindings reference. |
| `tests/` and `tools/` | Source-integration assertions and JPEG decoder checks. |

## Build boundary

This repository patches a local, uncommitted CircuitPython tree because CircuitPython does not provide a separate out-of-tree C-module mechanism. The usual loop is:

1. Regenerate the CircuitPython target in the pinned `lvgl-bindings` checkout when the binding shape changes.
2. Preview or apply the patch, for example `./apply_cp_patches.sh --dry-run --port unix --variant coverage`.
3. Build with CircuitPython's own `make`.
4. Run the pinned binding smoke script against the resulting interpreter.

The root [README](../README.md) has the exact setup, toolchain, Unix and Espressif commands. [Build and flash notes](build-and-flash.md) cover the Qualia S3 workflow. Keep the generated-binding smoke coverage in `lvgl-bindings`; this repository checks that its consumer integration is wired correctly.

## JPEG and multi-module boundary

LVGL's JPEG support here uses CircuitPython's `jpegio` implementation, not LVGL's bundled TJpgDec. When `CIRCUITPY_JPEGIO` is absent, the firmware still builds but does not register an LVGL JPEG decoder. PNG and LVGL BIN images do not need that optional piece.

Several PyDevices extensions can patch the same CircuitPython checkout. Apply each repository's `apply_cp_patches.sh` to that checkout, then run CircuitPython's `make` once; do not try to build them as independent C modules.

## A safe first contribution

Start with a focused change to the patch templates, allocator, or integration documentation. Run the patch script in `--dry-run` mode before applying it, keep the bindings pin aligned, and use the repository's source assertions plus the matching `lvgl-bindings` smoke suite for the affected target.

