# Contributing to lvgl-circuitpython

This repository integrates the generated LVGL bindings into a CircuitPython
firmware build. It is not a pip package and doesn't generate the bindings.
Change generator-owned code and the synced Python helper in
[lvgl-bindings](https://github.com/PyDevices/lvgl-bindings), then regenerate and
sync; don't edit their copied forms here. Change this repository for the module
sources, the allocator, the JPEG decoder or the integration. How to use the
module is in the [docs site](https://github.com/PyDevices/lvgl-bindings/blob/main/docs/index.md), built from
lvgl-bindings.

A good first change is a focused fix to the module sources, the allocator or the
build notes. Build the unix port before and after, keep the bindings pin
aligned, and use the repository's source assertions plus the matching
lvgl-bindings smoke suite for the target.

## Where things are

| Path | What it is |
|------|------------|
| `micropython.mk` | User C module glue: generated source and header, LVGL and the allocator |
| [`src/circuitpython_spike/`](src/circuitpython_spike/) | Hand-written `shared-bindings/lvgl` and `shared-module/lvgl` module sources |
| [`src/lv_mem_core_circuitpython.c`](src/lv_mem_core_circuitpython.c) | The GC-aware LVGL allocator |
| [`src/lv_assert_circuitpython.c`](src/lv_assert_circuitpython.c) | LVGL's assert hook for CircuitPython |
| [`src/lv_jpegio_decoder_circuitpython.c`](src/lv_jpegio_decoder_circuitpython.c) | LVGL's JPEG decoder over CircuitPython's own `lib/tjpgd` (the one `jpegio` uses), registered after `lv_init()` |
| [`lib/fs_driver.py`](lib/fs_driver.py) | LVGL filesystem driver, synced from lvgl-bindings |
| `manifest.py` | Freezes `lib/fs_driver.py` when the build names it in `FROZEN_MANIFEST` |
| [`scripts/partitions-16MB-lvgl.csv`](scripts/partitions-16MB-lvgl.csv) | A 16 MB partition table with a 4 MB app slot |
| [`scripts/fetch_bindings.sh`](scripts/fetch_bindings.sh), [`scripts/sync_from_lvgl_bindings.sh`](scripts/sync_from_lvgl_bindings.sh) | Fetch the pinned bindings into `.deps/`; refresh the helpers from an exact commit |
| `tests/` | Integration assertions, and the JPEG decode test |
| [`tools/host_jpegio_decoder_check.sh`](tools/host_jpegio_decoder_check.sh) | Host proof of the decoder shim without a CircuitPython build |
| `LVGL_BINDINGS_COMMIT` | The lvgl-bindings commit a build fetches when you give it no checkout |

## Work against a checkout

Lay out the repositories side by side:

```text
checkouts/
  lvgl-circuitpython/
  lvgl-bindings/
  circuitpython/
```

The usual loop: change the module sources under `src/`, rebuild with the
`make` line in
[Build CircuitPython firmware with LVGL](https://github.com/PyDevices/lvgl-bindings/blob/main/docs/guides/build-circuitpython-firmware-with-lvgl.md),
and run the smoke test. If the binding's shape changed, regenerate in
lvgl-bindings first so the generated source and header stay in step:

```bash
cd lvgl-bindings
git submodule update --init lvgl
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
./regenerate_all.sh --target circuitpython
```

## Sync from lvgl-bindings

Sync helpers only from an exact bindings SHA or a release tag:

```bash
./scripts/sync_from_lvgl_bindings.sh --ref <exact-ref>
```

The generated source, the header, the LVGL pin and the configuration must all
match the recorded commit. A checkout that doesn't builds with a note naming
the commit it is building.

## Test

The smoke suite comes from the exact pinned bindings source; this repository
doesn't duplicate or forward it. Run it with the interpreter you built:

```bash
./circuitpython/ports/unix/build-coverage/micropython ./lvgl-bindings/tools/test_lvgl_smoke.py
```

[`tests/test_integration.py`](tests/test_integration.py) reads the build files and sources and checks that
they are wired together.

[`tests/test_lvgl_jpeg_decode.py`](tests/test_lvgl_jpeg_decode.py) is the CircuitPython-side decoder test. It
renders `lv.image` on the jpegio corpus and compares the result to jpegio's
golden digests, and uses CircuitPython's own `jpegio` to `displayio.Bitmap` as
a second witness. The witness skips the right-edge MCU block of odd widths,
where CircuitPython's `bitmap_output()` mis-strides; that is a CircuitPython bug,
not the shim's. It needs the micropython-pydevices checkout beside this one for
the frames, or `JPEGIO_FRAMES=` pointing at them:

```bash
circuitpython tests/test_lvgl_jpeg_decode.py
```

Without a CircuitPython build, `tools/host_jpegio_decoder_check.sh` links LVGL,
CircuitPython's `lib/tjpgd` and the shim, renders the corpus and compares the
digests.

## Releases

lvgl-circuitpython has no versions of its own. A firmware build takes it from a
commit, and the binding it builds comes from the pinned lvgl-bindings commit.

## Don't change CircuitPython

Don't commit changes inside a CircuitPython checkout (such as `deps/circuitpython`).
Durable fixes belong here: `micropython.mk`, `scripts/partitions-16MB-lvgl.csv`
and the sources.
