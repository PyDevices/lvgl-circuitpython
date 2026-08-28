# CircuitPython build glue for LVGL + generated bindings.
#
# Include from a CircuitPython port Makefile after setting LV_CP_MOD_DIR:
#
#   LV_CP_MOD_DIR := $(abspath ../../lvgl-circuitpython)   # adjust relative to port dir
#   include $(LV_CP_MOD_DIR)/circuitpython.mk
#
# Requires:
#   - lvgl-bindings/generated/lvgl_circuitpython.c (run lvgl-bindings/regenerate_lvcp.sh)
#   - CIRCUITPY_LVGL=1 in port config (unix variant or board mpconfigboard.mk)

LV_CP_MOD_DIR ?= $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))
LV_BINDINGS_DIR ?= $(abspath $(LV_CP_MOD_DIR)/../lvgl-bindings)
LVGL_DIR := $(LV_BINDINGS_DIR)/lvgl
LVCP_C := $(LV_BINDINGS_DIR)/generated/lvgl_circuitpython.c
LVCP_H := $(LV_BINDINGS_DIR)/generated/lvgl_circuitpython.h
LV_BINDINGS_PIN := $(strip $(shell cat $(LV_CP_MOD_DIR)/LVGL_BINDINGS_COMMIT 2>/dev/null))
LV_BINDINGS_DIRTY := $(shell \
	git -C $(LV_BINDINGS_DIR) cat-file -e $(LV_BINDINGS_PIN)^{commit} 2>/dev/null && \
	git -C $(LV_BINDINGS_DIR) diff --quiet $(LV_BINDINGS_PIN) -- generated/lvgl_circuitpython.c generated/lvgl_circuitpython.h lvgl lv_conf.h && \
	git -C $(LV_BINDINGS_DIR) diff --quiet -- generated/lvgl_circuitpython.c generated/lvgl_circuitpython.h lvgl lv_conf.h || echo 1)

ifeq ($(LV_BINDINGS_PIN),)
$(error Missing $(LV_CP_MOD_DIR)/LVGL_BINDINGS_COMMIT)
endif
ifneq ($(LV_BINDINGS_DIRTY),)
$(error $(LV_BINDINGS_DIR) does not match pinned binding inputs $(LV_BINDINGS_PIN); check out that commit/tag or run scripts/sync_from_lvgl_bindings.sh with an exact ref)
endif

LV_CP_LVGL_SOURCES := $(shell find $(LVGL_DIR)/src -type f -name '*.c')
# CP coverage (and jpegio) already link lib/tjpgd; LVGL's copy uses incompatible tjpgdcnf.
LV_CP_LVGL_SOURCES := $(filter-out $(LVGL_DIR)/src/libs/tjpgd/tjpgd.c,$(LV_CP_LVGL_SOURCES))
# CIRCUITPY_GIFIO vendors AnimatedGIF/gif.c — apply_cp_patches forces
# CIRCUITPY_GIFIO=0 when CIRCUITPY_LVGL=1 so LVGL's libs/gif/gif.c (LV_USE_GIF)
# can link. No lvgl-bindings generator change; constraint is build-side.
LV_CP_SOURCES := $(LV_CP_MOD_DIR)/src/lv_mem_core_circuitpython.c

ifeq ($(wildcard $(LVCP_C)),)
$(error $(LVCP_C) not found. Run $(LV_BINDINGS_DIR)/regenerate_all.sh --target circuitpython)
endif
ifeq ($(wildcard $(LVCP_H)),)
$(error $(LVCP_H) not found. Run $(LV_BINDINGS_DIR)/regenerate_all.sh --target circuitpython)
endif
LV_CP_SOURCES += $(LVCP_C)

# CircuitPython allocator override (see lv_conf.h + src/lv_mem_core_circuitpython.c)
CFLAGS += -DLV_CIRCUITPYTHON_BUILD=1
CFLAGS += -I$(LV_BINDINGS_DIR) -I$(LVGL_DIR) -Wno-unused-function

# LVGL + generated bindings: suppress -Werror noise from upstream/generated C.
# -Wno-float-equal is CircuitPython-specific: it builds with -Werror=float-equal
# where MicroPython does not, and upstream widgets (arc, chart) compare floats
# directly. Scoped to these sources, never relaxed globally.
LVGL_SUPPRESS_CFLAGS := -Wno-cast-align -Wno-nested-externs -Wno-unused-parameter \
	-Wno-sign-compare -Wno-missing-prototypes -Wno-old-style-definition \
	-Wno-float-conversion -Wno-double-promotion -Wno-shadow -Wno-type-limits \
	-Wno-suggest-attribute=format -Wno-float-equal

# Spike module + generated bindings need LVGL headers during qstr/preprocess.
# Include LVGL_SUPPRESS_CFLAGS: spike .c files include lvgl.h (inline headers trip -Werror=cast-align on RISC-V).
$(BUILD)/shared-bindings/lvgl/%.o: CFLAGS += -I$(LV_BINDINGS_DIR) -I$(LVGL_DIR) -Wno-unused-const-variable $(LVGL_SUPPRESS_CFLAGS)
$(BUILD)/shared-module/lvgl/%.o: CFLAGS += -I$(LV_BINDINGS_DIR) -I$(LVGL_DIR) $(LVGL_SUPPRESS_CFLAGS)

$(foreach _lvsrc,$(LV_CP_LVGL_SOURCES),$(eval $(BUILD)/$(_lvsrc:.c=.o): CFLAGS += $(LVGL_SUPPRESS_CFLAGS)))
$(foreach _lvsrc,$(LV_CP_SOURCES),$(eval $(BUILD)/$(_lvsrc:.c=.o): CFLAGS += $(LVGL_SUPPRESS_CFLAGS)))

# LVGL + bindings + GC-aware allocator.
# LVGL core .c has no MP_QSTR_* — it must stay out of SRC_QSTR. Ports append
# SRC_C to SRC_QSTR; with ESP-IDF's huge QSTR_GEN_CFLAGS that argv exceeds
# ARG_MAX ("Argument list too long" on qstr.i.last). apply_cp_patches.sh
# rewrites SRC_QSTR += lines to filter-out $(LV_CP_LVGL_SOURCES).
SRC_C += $(LV_CP_LVGL_SOURCES) $(LV_CP_SOURCES)

# Hand-written module registration lives in the CP tree:
#   shared-bindings/lvgl/__init__.c  (spike; see src/circuitpython_spike/)
# Generated API surface and module object are declared by
# generated/lvgl_circuitpython.h and defined by generated/lvgl_circuitpython.c.
