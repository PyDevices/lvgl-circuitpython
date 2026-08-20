# lvgl-circuitpython

CircuitPython integration for LVGL: tree patches, build glue, spike templates, and tests.

This repo is a consumer/build repo for the LVGL stack: it consumes generated bindings from lvgl-bindings and rebuilds CircuitPython targets, but does not publish its own package. See [lvgl-bindings — The LVGL family](https://github.com/PyDevices/lvgl-bindings#the-lvgl-family) for how the family fits together.

Requires sibling clones of [lvgl-bindings](https://github.com/PyDevices/lvgl-bindings) (generated `lvcp.c`) and [circuitpython](https://github.com/adafruit/circuitpython). Check out a [stable release tag](https://github.com/adafruit/circuitpython/releases) — pick the version yourself; this repo does not track a specific CircuitPython version.

## Workspace layout

Place this repo as a sibling of `lvgl-bindings/` and `circuitpython/`:

```
workspace/
  lvgl-circuitpython/     ← this repo
  lvgl-bindings/
  circuitpython/
```

For day-to-day work, this repo is the place to patch CircuitPython’s LVGL integration, not the place to author the generator itself. The common loop is to change the patch set or the spike templates under **`src/`**, apply patches with **`./apply_cp_patches.sh --apply`**, rebuild with plain `make`, and smoke-test with the shared LVGL smoke script. If the underlying binding shape changed, regenerate **`lvgl-bindings`** first so the generated `lvcp.c` and header files stay in sync.

## 🚀 First-time setup

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
./regenerate_lvcp.sh
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

## Patch and build

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
./circuitpython/ports/unix/build-coverage/micropython ./lvgl-circuitpython/tools/test_lvgl_cp_unix.py
```

Prefer the unified smoke test directly: `lvgl-bindings/tools/test_lvgl_smoke.py`.

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

See the [cmods workspace](https://github.com/PyDevices/cmods) for an easier way to build this repo with other CircuitPython extensions.

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
| `circuitpython.mk` | Port Makefile fragment (LVGL + `lvcp.c` + allocator) |
| `apply_cp_patches.sh` | Patch CP tree and copy spike templates (`--apply`, `--force-apply`, `--status`) |
| `src/circuitpython_spike/` | Hand-written `shared-bindings/lvgl` module templates |
| `src/lv_mem_core_circuitpython.c` | GC-aware LVGL allocator |
| `manifest.py` | Freezes `lib/display_driver.py` (optional freeze helper) |
| `tools/test_lvgl_cp_unix.py` | Deprecated wrapper → `lvgl-bindings/tools/test_lvgl_smoke.py` |
| `docs/` | Integration notes |

See `src/circuitpython_spike/` for the spike layout and `docs/build-and-flash.md` for build details.

## Frozen Python

`manifest.py` freezes `lib/display_driver.py`. Sync from lvgl-bindings with `./scripts/sync_from_lvgl_bindings.sh`. Point CircuitPython’s `FROZEN_MANIFEST` at a wrapper that `include()`s this file (and any upstream freeze you still need).
