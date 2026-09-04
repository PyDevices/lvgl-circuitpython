// Copy to circuitpython/shared-module/lvgl/__init.c
//
// Port-independent LVGL init wrapper (no display driver here).

#include "lvgl.h"
#include "shared-module/lvgl/__init__.h"

// lvgl-circuitpython/src/lv_jpegio_decoder_circuitpython.c: LVGL's JPEG
// decoder on CircuitPython is jpegio's TJpgDec (lib/tjpgd), registered through
// lv_image_decoder_create after each LVGL init, because lvgl-bindings'
// lv_conf.h has LV_USE_TJPGD 0 here. No-ops in a build without CIRCUITPY_JPEGIO.
extern void lv_jpegio_decoder_circuitpython_init(void);
extern void lv_jpegio_decoder_circuitpython_deinit(void);

void shared_modules_lvgl_init(void) {
    lv_init();
    lv_jpegio_decoder_circuitpython_init();
}

void shared_modules_lvgl_deinit(void) {
    lv_jpegio_decoder_circuitpython_deinit();
    lv_deinit();
}
