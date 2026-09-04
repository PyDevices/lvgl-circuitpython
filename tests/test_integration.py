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
