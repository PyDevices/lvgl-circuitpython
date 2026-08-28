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
