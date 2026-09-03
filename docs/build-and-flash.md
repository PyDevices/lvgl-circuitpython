# CircuitPython + LVGL: build and flash notes

Lessons from building and flashing **Adafruit Qualia S3 RGB666** (`adafruit_qualia_s3_rgb666`) with full LVGL (2026-07-20). Sibling-clone workflow: this repo next to `circuitpython/` and `lvgl-bindings/`.

## Tooling locations

| Item | Path |
|------|------|
| LVGL patches | `./apply_cp_patches.sh` (this repo) |
| Make glue | `./circuitpython.mk` |
| 16MB LVGL partitions | `./scripts/partitions-16MB-lvgl.csv` |
| CircuitPython tree | sibling `circuitpython/` (upstream clone — do not commit) |
| CP build venv | local `.venv` with `circuitpython/requirements-dev.txt` |

```bash
# Patch + make (from this repo)
./apply_cp_patches.sh --apply --port espressif --board adafruit_qualia_s3_rgb666
cd ../circuitpython/ports/espressif
. ./esp-idf/export.sh
# Prefer PYTHON from a venv that has circuitpython/requirements-dev.txt
make -j BOARD=adafruit_qualia_s3_rgb666
```

See the [org's optional aggregator workspace](https://github.com/PyDevices/cmods) for an easier way to build this repo with other CircuitPython extensions.

## Board detection pitfalls

1. **Chip detect ≠ board id.** `mpftp firmware detect` / flash size + PSRAM (e.g. ESP32-S3, 16MB flash, 8MB OPI PSRAM) can match several boards. This Qualia was initially mis-identified as `espressif_esp32s3_devkitc_1_n8r8` while MicroPython was running; the correct CircuitPython board is `adafruit_qualia_s3_rgb666`.
2. Prefer an explicit board name from the user, silk, or a prior CircuitPython `sys.implementation._build` / `board.board_id` when available.
3. Qualia board flash config (in `mpconfigboard.mk`): `16MB` flash, `qio` / `120m`, `8MB` OPI PSRAM @ `120m`. USB VID/PID when running CP: `239A:8148`.

## Build: issues fixed and durable mitigations

### 1. `ARG_MAX` / “Argument list too long” on qstr

LVGL adds hundreds of `.c` files to `SRC_C`. Espressif’s huge `QSTR_GEN_CFLAGS` + `SRC_QSTR += $(SRC_C)` exceeds Linux `ARG_MAX` during qstr preprocess.

**Fix:** Keep LVGL sources in `SRC_C` for the link, but **exclude them from `SRC_QSTR`** (they have no `MP_QSTR_*`). `apply_cp_patches.sh` rewrites the port Makefile:

```make
SRC_QSTR += $(filter-out $(LV_CP_LVGL_SOURCES),$(SRC_C))
```

Documented in `circuitpython.mk`.

### 2. Python env after IDF `export.sh`

IDF export owns `python3` (needed for `idf_component_manager`). CircuitPython recipes need `minify_html` etc. from the CP venv.

**Fix:** After IDF export, set `PYTHON` to a venv that has CircuitPython `requirements-dev.txt` installed (for example `lvgl-circuitpython/.venv/bin/python`). Do **not** put the venv’s `python3` first on `PATH` before IDF export — that breaks component manager.

### 3. `-Werror=suggest-attribute=format` on LVGL

**Fix:** `-Wno-suggest-attribute=format` in `LVGL_SUPPRESS_CFLAGS` inside `circuitpython.mk`.

### 4. Duplicate `gif.c` (AnimatedGIF vs LVGL)

`lvgl-bindings/lv_conf.h` sets `LV_USE_GIF 1`, so LVGL’s `libs/gif/gif.c` is compiled. CircuitPython’s `CIRCUITPY_GIFIO` (defaults with displayio) vendors a colliding AnimatedGIF `gif.c`. The **bindings generator does not need changes** for this — it is a CircuitPython build conflict.

**Fix:** `apply_cp_patches.sh` forces `CIRCUITPY_GIFIO = 0` whenever `CIRCUITPY_LVGL=1` (shared `circuitpy_mpconfig.mk` and per-board enable block). After flipping GIFIO off on an existing build dir, delete stale genhdr:

```bash
rm -f build-<board>/genhdr/module/*gifio* build-<board>/genhdr/qstr/*gifio*
```

### 5. App partition too small (“Too little flash”)

Full LVGL app is ~**2.6–2.7 MB**. Stock `esp-idf-config/partitions-16MB.csv` has `ota_0 = 2048K`.

**Fix:** `partitions-16MB-lvgl.csv` with `ota_0 = 4096K` (moves `uf2` to `0x610000`, shrinks `user_fs`). `apply_cp_patches.sh` copies it to `ports/espressif/esp-idf-config/` and points the board `sdkconfig` at it for 16MB boards.

**Critical:** The CSV path in `sdkconfig` must be under `esp-idf-config/`. Paths outside the port tree are ignored by IDF confgen, and the build silently keeps the stock 2MB table. After changing partitions, wipe the board’s esp-idf build config if needed:

```bash
rm -rf circuitpython/ports/espressif/build-<board>/esp-idf
```

Verify in the built sdkconfig:

```text
CONFIG_PARTITION_TABLE_FILENAME="esp-idf-config/partitions-16MB-lvgl.csv"
```

Successful link reports ~`2704160 bytes used` against a **4096K** firmware region.

### Build artifacts

Under `circuitpython/ports/espressif/build-adafruit_qualia_s3_rgb666/`:

| File | Role |
|------|------|
| `circuitpython-firmware.bin` | App image only (flash at `0x10000`) |
| `firmware.bin` | Joined IDF bootloader + partition + app (esptool @ `0x0`) |
| `firmware.uf2` | From make; base address may be `0x0` (Adafruit convention) |

For TinyUF2 drag-drop, regenerate if needed:

```bash
python3 circuitpython/tools/uf2/utils/uf2conv.py -f 0xc47e5767 -b 0x0 -c \
  -o firmware-ota0.uf2 circuitpython-firmware.bin
```

Official Adafruit Qualia UF2s also use **start address `0x0`** (mapped into `ota_0` by TinyUF2), family `0xc47e5767` (ESP32-S3).

## Flashing on WSL2 + Windows

Serial is a Windows COM port. Use **Windows** Python:

```bash
python.exe -m esptool ...
```

Linux `esptool.py` / WSL device nodes do not see `COMn`.

### USB identity cheat sheet (Qualia / ESP32-S3)

| VID:PID | Meaning |
|---------|---------|
| `303A:4001` | USB-Serial/JTAG while app (e.g. MicroPython) is running |
| `303A:1001` | ROM download mode |
| `239A:0147` | TinyUF2 CDC; volume `TFT_S3BOOT` |
| `239A:8148` | CircuitPython on Qualia; volume `CIRCUITPY` |

### Entering ROM download mode (Qualia buttons)

Side stack: **Reset** (top), **UP**, **DN**. **Boot0** sits between UP and the MCU (not UP/DN).

```text
Hold Boot0 → press/release Reset → release Boot0
```

Expect `303A:1001` (often a **new** COM number, e.g. COM7 instead of COM8).

### What does *not* work well on this USB-Serial/JTAG path

- **`machine.bootloader()`** from MicroPython: enters download mode but often leaves Windows with `PermissionError 31` (“device … not functioning”). Needs unplug/replug.
- **`esptool --before usb-reset` / `default-reset`** while the app owns the port: typically `Invalid head of packet (0x08)` (REPL noise).
- **`esptool --after hard-reset` / RTS reset:** often leaves the chip in ROM (`303A:1001`). Prefer a **physical Reset** (no Boot0) after flashing.
- **esptool 5.x** rejects `--flash-freq 120m`. Use `80m` or `keep`. Qualia wants 120m in board config; `80m` was fine for TinyUF2/Adafruit `flash_args` and for our successful flashes.

### Do not flash joined `firmware.bin` if you want Adafruit TinyUF2

CircuitPython’s joined `firmware.bin` replaces the second-stage path with the **IDF bootloader**. Adafruit’s documented flow uses **TinyUF2** (`combined.bin` from [tinyuf2 releases](https://github.com/adafruit/tinyuf2/releases) for `adafruit_qualia_s3_rgb666`).

Stock TinyUF2 layout (`ota_0 = 2048K`) **cannot** hold a ~2.6MB LVGL app. LVGL needs the 4MB table (above), which moves the `uf2` factory partition to `0x610000`.

## Recommended flash recipe (Qualia + LVGL)

Proven end-to-end sequence:

### A. Build

```bash
./apply_cp_patches.sh --apply --port espressif --board adafruit_qualia_s3_rgb666
cd ../circuitpython/ports/espressif
. ./esp-idf/export.sh
make -j BOARD=adafruit_qualia_s3_rgb666
```

Confirm `build-adafruit_qualia_s3_rgb666/circuitpython-firmware.bin` ≈ 2.6MB and partition filename is `partitions-16MB-lvgl.csv`.

### B. Install Adafruit TinyUF2 + 4MB partitions + app (ROM mode)

Download TinyUF2 **0.35.0** zip for Qualia; use `bootloader.bin`, `tinyuf2.bin`, `ota_data_initial.bin` from the zip. Generate partition table bin from `partitions-16MB-lvgl.csv` via IDF `gen_esp32part.py`.

In ROM (`303A:1001`):

```bash
python.exe -m esptool --chip esp32s3 -p COMx --before no-reset --after no-reset --baud 460800 \
  write-flash --flash-mode dio --flash-freq 80m --flash-size 16MB \
  0x0      bootloader.bin \
  0x8000   partition-table-lvgl.bin \
  0xe000   ota_data_initial.bin \
  0x10000  circuitpython-firmware.bin \
  0x610000 tinyuf2.bin
```

Then **physical Reset** (no Boot0).

### C. Blank `otadata` boots TinyUF2, not the app

`ota_data_initial.bin` from the TinyUF2 zip is **all `0xFF`**. With a `factory` (uf2) partition present, the ESP bootloader selects **TinyUF2** → `TFT_S3BOOT`, even if `ota_0` already has a valid app.

**Fix:** With `TFT_S3BOOT` mounted, copy the LVGL `.uf2` (addr `0x0`) onto the drive. TinyUF2 programs `ota_0` and updates otadata. After a successful copy, expect `CIRCUITPY` and `239A:8148`.

```powershell
Copy-Item -Force qualia-lvgl.uf2 D:\firmware.uf2
```

`INFO_UF2.TXT` should show `Flash Size: 0x00400000` (4MB app window) when the LVGL partition table is active. Stock TinyUF2 shows `0x00200000` (2MB).

### D. Stock Adafruit path (no LVGL)

For a known-good baseline without LVGL:

1. ROM mode → flash TinyUF2 zip **`combined.bin`** @ `0x0` (`dio` / `80m` / `16MB` per `flash_args`).
2. Reset → `TFT_S3BOOT`.
3. Copy official UF2 from  
   `https://downloads.circuitpython.org/bin/adafruit_qualia_s3_rgb666/en_US/adafruit-circuitpython-adafruit_qualia_s3_rgb666-en_US-10.2.1.uf2`

Official app is ~1.8MB payload — fits 2MB `ota_0`.

## Verify

```text
Adafruit CircuitPython 10.2.1-dirty ... Adafruit-Qualia-S3-RGB666
>>> import lvgl
>>> print(lvgl)   # <module 'lvgl'>
```

## Quick failure matrix

| Symptom | Likely cause | Action |
|---------|--------------|--------|
| `Argument list too long` / qstr | LVGL in `SRC_QSTR` | Ensure `filter-out $(LV_CP_LVGL_SOURCES)` patch |
| `minify_html` missing | Wrong Python after IDF export | `PYTHON=…/lvgl-circuitpython/.venv/bin/python` |
| Duplicate `GIF_*` at link | GIFIO + LVGL gif | `CIRCUITPY_GIFIO = 0`; clean gifio genhdr |
| `Too little flash` / 2MB region | Stock partition CSV still selected | CSV under `esp-idf-config/`; wipe `build-*/esp-idf` |
| `0x08` / can’t sync esptool | App owns USB | Boot0+Reset → ROM (`303A:1001`) |
| COM “not functioning” | After `machine.bootloader()` | Unplug/replug |
| Stuck `303A:1001` after flash | RTS “reset” ineffective | Physical Reset |
| `TFT_S3BOOT` despite flashed app | Blank otadata + factory UF2 | Copy `.uf2` to BOOT drive once |
| UF2 copy ignored (stays on BOOT) | Wrong/relocated TinyUF2 install, or app > Flash Size | Use recipe B/C; check `INFO_UF2.TXT` Flash Size |
| LVGL UF2 rejected on stock TinyUF2 | App > 2MB | 4MB partition table required |

## Upstream / commit policy

- Do **not** commit changes inside `circuitpython/` (or `micropython/`) unless explicitly overridden.
- Durable fixes belong in `lvgl-circuitpython/` (`apply_cp_patches.sh`, `circuitpython.mk`, `scripts/partitions-16MB-lvgl.csv`).
