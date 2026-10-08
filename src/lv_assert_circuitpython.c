/**
 * @file lv_assert_circuitpython.c
 *
 * What an LVGL assertion does on CircuitPython (lvgl-bindings' lv_conf.h
 * names this function as LV_ASSERT_HANDLER when LV_CIRCUITPYTHON_BUILD is
 * set). LVGL's default is to spin forever, and a board spinning in C stops
 * answering USB: its drive and serial port vanish until someone presses reset.
 * Most LVGL assertions on a board are an allocation that failed because the
 * heap is full, so instead the board reboots into safe mode, which reports
 * "Third-party firmware fatal error." and keeps CIRCUITPY reachable to fix
 * code.py. On the unix port the process aborts.
 */
#include "py/mpconfig.h"

void lv_circuitpython_assert_failed(void);

#if defined(__unix__) || defined(__APPLE__)
#include <stdlib.h>

void lv_circuitpython_assert_failed(void) {
    abort();
}
#else
#include "supervisor/shared/safe_mode.h"

void lv_circuitpython_assert_failed(void) {
    reset_into_safe_mode(SAFE_MODE_SDK_FATAL_ERROR);
}
#endif
