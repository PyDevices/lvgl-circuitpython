// Copy to circuitpython/shared-bindings/lvgl/__init__.c
//
// module dict + bindings live in generated/lvgl_circuitpython.c.

#include "py/runtime.h"
#include "py/obj.h"
#include "shared-bindings/lvgl/__init__.h"
#include "shared-module/lvgl/__init__.h"
#include "generated/lvgl_circuitpython.h"

extern void mp_lv_deinit_gc(void);

static mp_obj_t lvgl_module_init_fn(void) {
    lvgl_init();
    return mp_const_none;
}
MP_DEFINE_CONST_FUN_OBJ_0(lvgl_init_obj, lvgl_module_init_fn);

static mp_obj_t lvgl_module_deinit_fn(void) {
    lvgl_deinit();
    return mp_const_none;
}
MP_DEFINE_CONST_FUN_OBJ_0(lvgl_deinit_obj, lvgl_module_deinit_fn);

MP_REGISTER_MODULE(MP_QSTR_lvgl, lvgl_module);

#if MICROPY_MODULE_BUILTIN_INIT && MICROPY_MODULE_ATTR_DELEGATION
// CircuitPython starts a new VM on every reload (a saved file, Ctrl-D,
// supervisor.reload()) and does not clear root pointers between VMs. LVGL's
// state, lv_global_t and everything it reaches, lives on the GC heap behind
// them, so in the next VM they point into a heap that has been wiped:
// lv.is_initialized() reads garbage and the first display_create asks for
// megabytes. A built-in module's __init__ runs on its first import in each VM;
// the generated module dict has none, so this delegation answers the lookup,
// and the stale state is dropped before anything reads it. (Deleting lvgl
// from sys.modules and importing it again in the same VM drops live state
// too; LVGL is then initialised afresh.)
static mp_obj_t lvgl_module_vm_init(void) {
    mp_lv_deinit_gc();
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(lvgl_module_vm_init_obj, lvgl_module_vm_init);

void lvgl_module_attr(mp_obj_t self_in, qstr attr, mp_obj_t *dest);
void lvgl_module_attr(mp_obj_t self_in, qstr attr, mp_obj_t *dest) {
    (void)self_in;
    if (dest[0] == MP_OBJ_NULL && attr == MP_QSTR___init__) {
        dest[0] = MP_OBJ_FROM_PTR(&lvgl_module_vm_init_obj);
    }
}
MP_REGISTER_MODULE_DELEGATION(lvgl_module, lvgl_module_attr);
#endif

void lvgl_init(void) {
    shared_modules_lvgl_init();
}

void lvgl_deinit(void) {
    shared_modules_lvgl_deinit();
    mp_lv_deinit_gc();
}
