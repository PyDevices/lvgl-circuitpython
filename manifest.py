# Frozen Python helpers that ship with the LVGL CircuitPython integration.
# Source of truth: PyDevices/lvgl-bindings python/ (fs_driver.py). LVGL's
# PyDevices coordinator, display_driver.py, ships with pydevices (lib/): put
# pydevices on CIRCUITPY as source, as you do for appdev, events and keys.
# Sync: ./scripts/sync_from_lvgl_bindings.sh
#
# Freeze-only: upstream port/board/variant frozen modules come from a
# workspace aggregator via FROZEN_MANIFEST_UPSTREAM.

module("fs_driver.py", base_path="./lib", opt=3)
