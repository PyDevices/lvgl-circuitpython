# Newcomer's guide to lvgl-circuitpython

`lvgl-circuitpython` integrates PyDevices' generated LVGL bindings into a
CircuitPython firmware build. It supplies the user C module glue,
a GC-aware LVGL allocator, synced Python helpers, and a CircuitPython-specific
JPEG decoder.

It is not a pip package and does not generate the bindings. Work with sibling
clones of [lvgl-bindings](https://github.com/PyDevices/lvgl-bindings) and
[CircuitPython](https://github.com/adafruit/circuitpython). The bindings
revision this repository is tested with is recorded in `LVGL_BINDINGS_COMMIT`;
a checkout at another commit builds with a note saying so.

## First use: the firmware application

After building firmware that includes this integration, you import
`display_driver` before `lvgl` and then run `app.run()` (or your own `asyncio`
loop) to pump LVGL, because CircuitPython has no `machine.Timer` for this role.
The README's [App Usage & Timer Model](../README.md#app-usage--timer-model) has
the example.

`display_driver` is pydevices', not this firmware's: it comes with pydevices,
beside the `appdev`, `events`, `keys` and `multimer` it imports, and wants a
`board_config` unless your code has already created an `appdev.App`. Put
pydevices (as source) and the board config on the device.

## The mental model

```text
lvgl-bindings at the pinned generated revision
                  |
                  v
lvgl-circuitpython user C module glue
                  |
                  +--> CircuitPython shared-bindings/shared-module/lvgl
                  +--> generated C source/header + allocator
                  +--> manifest.py (freezes fs_driver when the build
                  |    passes it via FROZEN_MANIFEST)
                  |
                  v
CircuitPython firmware + pydevices: import display_driver, then import lvgl
```

The generated source, header, LVGL pin, and configuration must all match the
recorded bindings commit. Change generator-owned code and the synced Python
helper in `lvgl-bindings`, then regenerate and synchronize; do not edit their
copied forms here.

## Repository map

The README's [Files](../README.md#files) table says what each path is for. The
one you meet first is `micropython.mk`, the user C module glue CircuitPython's
make reads. The synced helper
is `lib/fs_driver.py`; `manifest.py` freezes it when the build names it in
`FROZEN_MANIFEST`.

## Build boundary

CircuitPython 11 builds user C modules the way MicroPython does, so this
repository is handed to CircuitPython's own make as `USER_C_MODULES` and
nothing in the CircuitPython tree is patched. The usual loop is:

1. Regenerate the CircuitPython target in the pinned `lvgl-bindings` checkout when the binding shape changes.
2. Build with CircuitPython's own `make` and `USER_C_MODULES=` pointing here, passing `FROZEN_MANIFEST` if you want the helpers frozen.
3. Or build through micropython-pydevices' `build_mp.py --interpreter circuitpython`, which does the same and adds the other PyDevices modules.
4. Run the pinned binding smoke script against the resulting interpreter.

The root [README](../README.md) has the exact setup, toolchain, Unix and
Espressif commands. [Build and flash notes](build-and-flash.md) cover the Qualia
S3 workflow. Keep the generated-binding smoke coverage in `lvgl-bindings`; this
repository checks that its consumer integration is wired correctly.

## JPEG and multi-module boundary

LVGL's JPEG support here uses CircuitPython's `jpegio` implementation, not
LVGL's bundled TJpgDec. When `CIRCUITPY_JPEGIO` is absent, the firmware still
builds but does not register an LVGL JPEG decoder. PNG and LVGL BIN images do
not need that optional piece.

To build this together with other PyDevices extensions, see the README's [Build
with other extensions](../README.md#build-with-other-extensions).

## A safe first contribution

Start with a focused change to the module sources, allocator, or integration
documentation. Build the Unix port before and after, keep
the bindings pin aligned, and use the repository's source assertions plus the
matching `lvgl-bindings` smoke suite for the affected target.

