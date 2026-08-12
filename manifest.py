# Frozen Python helpers that ship with the LVGL CircuitPython integration.
# Source of truth: PyDevices/lvgl-bindings python/display_driver.py
# Sync: ./scripts/sync_from_lvgl_bindings.sh
#
# Freeze-only: upstream port/board/variant frozen modules come from a
# workspace aggregator via FROZEN_MANIFEST_UPSTREAM.

module("display_driver.py", base_path="./lib", opt=3)
