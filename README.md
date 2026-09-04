# lvgl-circuitpython

CircuitPython integration for LVGL: tree patches, build glue, spike templates, and tests.

This repo is a consumer/build repo for the LVGL stack: it consumes generated bindings from lvgl-bindings and rebuilds CircuitPython targets, but does not publish its own package. See [lvgl-bindings — The LVGL family](https://github.com/PyDevices/lvgl-bindings#the-lvgl-family) for how the family fits together.

Requires sibling clones of [lvgl-bindings](https://github.com/PyDevices/lvgl-bindings) and [circuitpython](https://github.com/adafruit/circuitpython). The generated source, generated header, LVGL pin, and configuration must match the exact bindings commit recorded in `LVGL_BINDINGS_COMMIT`.

**Synced from lvgl-bindings:** `lib/display_driver.py` and `lib/fs_driver.py` are synced from [lvgl-bindings](https://github.com/PyDevices/lvgl-bindings) at the commit pinned in `LVGL_BINDINGS_COMMIT`, along with the generated bindings. Do not edit them here — change them in lvgl-bindings and re-sync.

## Workspace layout

Place this repo as a sibling of `lvgl-bindings/` and `circuitpython/`:

```
workspace/
  lvgl-circuitpython/     ← this repo
  lvgl-bindings/
  circuitpython/
```

For day-to-day work, this repo is the place to patch CircuitPython’s LVGL integration, not the place to author the generator itself. The common loop is to change the patch set or the spike templates under **`src/`**, apply patches with **`./apply_cp_patches.sh --apply`**, rebuild with plain `make`, and smoke-test with the shared LVGL smoke script. If the underlying binding shape changed, regenerate **`lvgl-bindings`** first so the generated `lvcp.c` and header files stay in sync.

## First-time setup

```bash
# Pick a stable release tag from https://github.com/adafruit/circuitpython/releases
git clone --branch 10.2.1 https://github.com/adafruit/circuitpython.git circuitpython
cd circuitpython
make fetch-all-submodules
cd ..

git clone https://github.com/PyDevices/lvgl-bindings.git lvgl-bindings
cd lvgl-bindings
git submodule update --init lvgl
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
./regenerate_all.sh --target circuitpython
cd ..
```

## Build environment

Install system build tools and cross-compilers **before** building CircuitPython. Follow CircuitPython’s own documentation — this repo does not install compilers or apt packages for you.

- [circuitpython/building.md](https://github.com/adafruit/circuitpython/blob/main/building.md) in your clone
- Adafruit Learn: [Building CircuitPython on Linux](https://learn.adafruit.com/building-circuitpython/linux) (or macOS / WSL as appropriate)

Typical Linux setup includes packages such as `build-essential`, `cmake`, `python3`, and port-specific tools (for example `gcc-arm-none-eabi` and related newlib packages for `raspberrypi`). Exact packages depend on the port you build.

Current stable CircuitPython releases require **GCC 14** or newer when compiling firmware. Check the compiler your port uses (for embedded boards, usually `arm-none-eabi-gcc --version`). Ubuntu’s `gcc-arm-none-eabi` package is often GCC 13 — too old for current CircuitPython.

Install a **system-wide** Arm GNU Toolchain 14+ (not under your home directory or this repo). Example on Linux:

```bash
# Download (or use an existing .tar.xz)
curl -fLO https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-eabi.tar.xz

# Install under /opt and expose to all users
sudo tar -xJf arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-eabi.tar.xz -C /opt
printf '%s\n' 'export PATH="/opt/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-eabi/bin:$PATH"' \
  | sudo tee /etc/profile.d/arm-gnu-toolchain.sh
sudo chmod 644 /etc/profile.d/arm-gnu-toolchain.sh

# Activate in the current shell, then verify
source /etc/profile.d/arm-gnu-toolchain.sh
arm-none-eabi-gcc --version   # should report GCC 14.x
which arm-none-eabi-gcc       # should be under /opt/..., not /usr/bin
```

Open a new terminal (or `source /etc/profile.d/arm-gnu-toolchain.sh`) before building.

Create a Python venv for CircuitPython’s `requirements-dev.txt` (needed for `minify_html` and related tools). If `minify_html` fails to install, you may need Rust (see CircuitPython `building.md`).

```bash
python3 -m venv .venv
.venv/bin/pip install -r ../circuitpython/requirements-dev.txt
export PATH="$(pwd)/.venv/bin:$PATH"
```

## Build with the org's aggregator workspace (optional)

As an optional convenience, the org's sibling [aggregator workspace](https://github.com/PyDevices/cmods) applies the patches and invokes CircuitPython's build tooling for you:

```bash
cd ../cmods
./build_cp.sh --port unix --variant coverage
./build_cp.sh --port espressif --board adafruit_qualia_s3_rgb666
```

## Direct patch and build

Adafruit’s [Extending CircuitPython](https://learn.adafruit.com/extending-circuitpython)
guide (and the [design guide — native modules](https://docs.circuitpython.org/en/latest/docs/design_guide.html))
describe adding `shared-bindings/` + `shared-module/` **inside** the CircuitPython
tree. This repo keeps those sources out-of-tree under `src/circuitpython_spike/`
and applies them with `./apply_cp_patches.sh` into a local (uncommitted)
CircuitPython clone — Adafruit has no separate out-of-tree C-module path.
See `src/circuitpython_spike/` for the spike layout.

| Adafruit step | This repo |
|---------------|-----------|
| `shared-bindings/<mod>/` | `src/circuitpython_spike/shared-bindings/lvgl/` |
| `shared-module/<mod>/` | `src/circuitpython_spike/shared-module/lvgl/` |
| Enable `CIRCUITPY_*` | Patches set `CIRCUITPY_LVGL` (and `CIRCUITPY_GIFIO=0`) |
| List sources in port Makefile | Board/variant `.mk` + `SRC_PATTERNS` + `circuitpython.mk` |
| Build | `make` after `--apply` |

```bash
cd lvgl-circuitpython
./apply_cp_patches.sh --dry-run --port unix --variant coverage
./apply_cp_patches.sh --apply --port unix --variant coverage
./apply_cp_patches.sh --force-apply --port unix --variant coverage  # reinstall patches
cd ../circuitpython/ports/unix
make -j VARIANT=coverage
```

Espressif example:

```bash
cd lvgl-circuitpython
./apply_cp_patches.sh --apply --port espressif --board adafruit_qualia_s3_rgb666
cd ../circuitpython/ports/espressif
. ./esp-idf/export.sh
make -j BOARD=adafruit_qualia_s3_rgb666
```

Smoke test:

```bash
./circuitpython/ports/unix/build-coverage/micropython ./lvgl-bindings/tools/test_lvgl_smoke.py
```

The smoke suite comes directly from the exact pinned bindings source; this repo does not duplicate or forward it.

## App Usage & Timer Model

CircuitPython does not provide `machine.Timer` or signal FFI. In CircuitPython, `display_driver` and `multimer` operate via cooperative `asyncio` or pumped timers:
- Applications run `app.run()` or an `asyncio` loop to continuously pump LVGL tasks and events.

```python
import display_driver  # noqa: F401 - initializes display and input
import lvgl as lv
from display_driver import app

scr = lv.screen_active()
label = lv.label(scr)
label.set_text("Hello CircuitPython LVGL!")
label.center()

app.run()
```

See the [org's optional aggregator workspace](https://github.com/PyDevices/cmods) for an easier way to build this repo with other CircuitPython extensions.

## Environment variables

| Variable | Default |
|----------|---------|
| `WORKSPACE_DIR` | Parent of this repo |
| `CP_DIR` | Sibling `circuitpython/` (or set explicitly) |
| `PORT` | (prompted or pass `--port`) |
| `BOARD` | (prompted or pass `--board`) |
| `VARIANT` | (prompted or pass `--variant`) |


## Files

| Path | Role |
|------|------|
| `circuitpython.mk` | Port Makefile fragment (generated source/header + LVGL + allocator) |
| `apply_cp_patches.sh` | Patch CP tree and copy spike templates (`--apply`, `--force-apply`, `--status`) |
| `src/circuitpython_spike/` | Hand-written `shared-bindings/lvgl` module templates |
| `src/lv_mem_core_circuitpython.c` | GC-aware LVGL allocator |
| `src/lv_jpegio_decoder_circuitpython.c` | LVGL JPEG decoder over CircuitPython's own `lib/tjpgd` (the one `jpegio` uses); registered from the spike after `lv_init()` |
| `tests/test_lvgl_jpeg_decode.py` | CircuitPython-side test: `lv.image` on the jpegio corpus vs. jpegio's golden digests (run with the built `circuitpython`) |
| `tools/host_jpegio_decoder_check.sh` | Host proof of the decoder shim without a CircuitPython build: links LVGL + CP's `lib/tjpgd` + the shim, renders the corpus, compares digests |
| `manifest.py` | Freezes `lib/display_driver.py` (optional freeze helper) |
| `LVGL_BINDINGS_COMMIT` | Exact generator/artifact source consumed by builds |
| `docs/` | Integration notes |

See `src/circuitpython_spike/` for the spike layout and `docs/build-and-flash.md` for build details.

## JPEG decoding

One TJpgDec per firmware (org `docs/jpegio-vision.md`, Phase 2): the pinned
lvgl-bindings `lv_conf.h` sets `LV_USE_TJPGD 0` on CircuitPython, so LVGL's
`libs/tjpgd` compiles to nothing, and `src/lv_jpegio_decoder_circuitpython.c`
registers CircuitPython's `lib/tjpgd` (compiled whenever `CIRCUITPY_JPEGIO=1`)
as LVGL's JPEG decoder through the public `lv_image_decoder_create` API. Decoded
images are `LV_COLOR_FORMAT_RGB565_SWAPPED`, exactly what `jpegio` produces
(CP's `tjpgd.c` byte-swaps); LVGL's software renderer swaps them back onto an
RGB565 display. The sniff is SOI-only, so non-JFIF UVC MJPEG frames decode;
scale is always 0. A build without `CIRCUITPY_JPEGIO` still links -- it just
has no JPEG decoder for LVGL. `lv.tjpgd_init` does not exist on CircuitPython.

```bash
bin/circuitpython tests/test_lvgl_jpeg_decode.py   # needs ../displayif (corpus) or JPEGIO_FRAMES=
```

## Frozen Python

`manifest.py` freezes the Python helpers. An aggregator workspace's manifest includes
it together with the selected port/board upstream manifest. Sync helpers only
from an exact bindings SHA or release tag with
`./scripts/sync_from_lvgl_bindings.sh --ref <exact-ref>`.
