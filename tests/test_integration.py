from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_bindings_pin_is_an_exact_commit():
    pin = (ROOT / "LVGL_BINDINGS_COMMIT").read_text().strip()
    assert len(pin) == 40
    assert all(character in "0123456789abcdef" for character in pin)


def test_generated_source_and_header_are_both_required():
    make = (ROOT / "circuitpython.mk").read_text()
    assert "generated/lvgl_circuitpython.c" in make
    assert "generated/lvgl_circuitpython.h" in make
    assert "LVGL_BINDINGS_COMMIT" in make
    assert "regenerate_lvcp.sh" not in make


def test_lifecycle_and_registration_have_single_owners():
    shared_bindings = (
        ROOT / "src/circuitpython_spike/shared-bindings/lvgl/__init__.c"
    ).read_text()
    shared_module = (
        ROOT / "src/circuitpython_spike/shared-module/lvgl/__init__.c"
    ).read_text()
    assert 'generated/lvgl_circuitpython.h' in shared_bindings
    assert "MP_REGISTER_MODULE(MP_QSTR_lvgl, lvgl_module);" in shared_bindings
    assert shared_bindings.count("void lvgl_init(void)") == 1
    assert shared_bindings.count("void lvgl_deinit(void)") == 1
    assert shared_module.count("lv_init();") == 1
    assert shared_module.count("lv_deinit();") == 1


def test_no_consumer_smoke_wrapper_remains():
    assert not (ROOT / "tools" / "test_lvgl_cp_unix.py").exists()


def test_patch_script_reports_success_without_legacy_regeneration_wrappers():
    script = (ROOT / "apply_cp_patches.sh").read_text()
    assert script.rstrip().endswith("exit 0")
    assert "regenerate_lvcp.sh" not in script


def test_jpegio_decoder_shim_is_wired():
    make = (ROOT / "circuitpython.mk").read_text()
    shim = ROOT / "src/lv_jpegio_decoder_circuitpython.c"
    spike = (ROOT / "src/circuitpython_spike/shared-module/lvgl/__init__.c").read_text()
    assert shim.is_file()
    assert "src/lv_jpegio_decoder_circuitpython.c" in make
    # LVGL's tjpgd.c is #if LV_USE_TJPGD, which is 0 on CircuitPython: no filter.
    assert "filter-out $(LVGL_DIR)/src/libs/tjpgd/tjpgd.c" not in make
    assert spike.count("lv_jpegio_decoder_circuitpython_init();") == 1
    assert spike.index("lv_init();") < spike.index("lv_jpegio_decoder_circuitpython_init();")
    text = shim.read_text()
    assert "lv_image_decoder_create()" in text
    assert "LV_COLOR_FORMAT_RGB565_SWAPPED" in text
    assert "defined(CIRCUITPY_JPEGIO) && CIRCUITPY_JPEGIO" in text
    # File sources are sniffed by their first two bytes, like variable sources
    # and like displayif's shim on MicroPython -- never by extension.
    assert "file_has_soi" in text
    assert "lv_fs_get_ext" not in text
    assert "has_jpeg_ext" not in text


def test_user_c_module_keeps_lvgl_out_of_the_qstr_scan():
    make = (ROOT / "micropython.mk").read_text()
    # LVGL has no MP_QSTR_*: compiled and linked, never scanned.
    assert "SRC_USERMOD_LIB_C += $(LVCP_LVGL_SOURCES)" in make
    assert "SRC_USERMOD_C += $(LVCP_SOURCES)" in make
    assert "generated/lvgl_circuitpython.c" in make
    assert "LVGL_BINDINGS_COMMIT" in make
    # gifio's AnimatedGIF collides with LVGL's at link time: stop early.
    assert "ifeq ($(CIRCUITPY_GIFIO),1)" in make
    # The board ports' late -Werror flags lose to per-object flags only.
    assert "CFLAGS += $(LVCP_OBJ_CFLAGS)" in make


def test_a_reload_drops_lvgl_state_from_the_previous_vm():
    shared_bindings = (
        ROOT / "src/circuitpython_spike/shared-bindings/lvgl/__init__.c"
    ).read_text()
    assert "MP_REGISTER_MODULE_DELEGATION(lvgl_module, lvgl_module_attr);" in shared_bindings
    assert "attr == MP_QSTR___init__" in shared_bindings
    assert "mp_lv_deinit_gc();" in shared_bindings


def test_an_lvgl_failure_never_spins_a_board_off_usb():
    mem = (ROOT / "src/lv_mem_core_circuitpython.c").read_text()
    # NULL, not MemoryError: an exception would longjmp out of LVGL's C.
    assert "m_malloc_maybe(size)" in mem
    assert "m_realloc_maybe(p, new_size, true)" in mem
    handler = (ROOT / "src/lv_assert_circuitpython.c").read_text()
    assert "reset_into_safe_mode(SAFE_MODE_SDK_FATAL_ERROR)" in handler
    assert "src/lv_assert_circuitpython.c" in (ROOT / "micropython.mk").read_text()
    assert "src/lv_assert_circuitpython.c" in (ROOT / "circuitpython.mk").read_text()
