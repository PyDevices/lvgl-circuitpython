/* Host twin of lvgl-circuitpython/src/lv_mem_core_circuitpython.c: the same
 * LV_STDLIB_CIRCUITPYTHON_OVERRIDE entry points over plain malloc, so LVGL can
 * be linked on the host with the CircuitPython lv_conf.h and no CP tree. */
#include "lvgl/src/stdlib/lv_mem.h"
#include <stdlib.h>

#ifndef LV_STDLIB_CIRCUITPYTHON_OVERRIDE
#define LV_STDLIB_CIRCUITPYTHON_OVERRIDE 253
#endif
#if LV_USE_STDLIB_MALLOC != LV_STDLIB_CIRCUITPYTHON_OVERRIDE
#error "expected the CircuitPython allocator override (compile with -DLV_CIRCUITPYTHON_BUILD=1)"
#endif

void lv_mem_init(void) {}
void lv_mem_deinit(void) {}
lv_mem_pool_t lv_mem_add_pool(void *mem, size_t bytes) { LV_UNUSED(mem); LV_UNUSED(bytes); return NULL; }
void lv_mem_remove_pool(lv_mem_pool_t pool) { LV_UNUSED(pool); }
void *lv_malloc_core(size_t size) { return malloc(size); }
void *lv_realloc_core(void *p, size_t new_size) { return realloc(p, new_size); }
void lv_free_core(void *p) { free(p); }
void lv_mem_monitor_core(lv_mem_monitor_t *mon_p) { LV_UNUSED(mon_p); }
lv_result_t lv_mem_test_core(void) { return LV_RESULT_OK; }

/* Host twins of the generated binding's LV_GLOBAL_CUSTOM / LV_GC_INIT hooks
 * (lv_conf.h:318-329; generated/lvgl_circuitpython.c:367-387): lv_global_t
 * lives on the heap and LVGL reaches it through mp_lv_get_roots(). */
#include "lvgl/src/lvgl_private.h"
static lv_global_t *host_roots;
void *mp_lv_get_roots(void);
void mp_lv_init_gc(void);
void mp_lv_deinit_gc(void);
void *mp_lv_get_roots(void) { return host_roots; }
void mp_lv_init_gc(void) { if(!host_roots) host_roots = calloc(1, sizeof(lv_global_t)); }
void mp_lv_deinit_gc(void) { free(host_roots); host_roots = NULL; }
