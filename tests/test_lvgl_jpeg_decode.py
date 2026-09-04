"""lv.image decodes jpegio's corpus on CircuitPython through the jpegio decoder shim.

The CircuitPython half of jpegio Phase 2 (org docs/jpegio-vision.md): LVGL's
own TJPGD is off (lvgl-bindings lv_conf.h, LV_USE_TJPGD 0 on CircuitPython),
and src/lv_jpegio_decoder_circuitpython.c registers CircuitPython's lib/tjpgd
-- the TJpgDec `jpegio` decodes with -- as LVGL's JPEG decoder, labelled
LV_COLOR_FORMAT_RGB565_SWAPPED because CP's tjpgd.c byte-swaps (decision D2).

Checks, all plain asserts:

  1. lv.tjpgd_init / lv.tjpgd_deinit are absent (LVGL's decoder is off here).
  2. lv.image on each corpus frame renders onto a native RGB565 display and the
     flushed pixels, cropped to the image, hash to jpegio's own golden digest
     for that frame at scale 0 (displayif tests/jpegio/frames/golden_tjpgd.json,
     native-order RGB565, tight). No swap is applied to the expected bytes: the
     decoder hands LVGL RGB565_SWAPPED pixels and LVGL's software blend swaps
     them back onto the RGB565 display (lv_draw_sw_blend_to_rgb565.c,
     rgb565_swapped_image_blend: memcpy + swap, exact), so the digest of what
     reaches flush_cb is jpegio's native-order digest unchanged.
  3. Second witness, independent of the golden file: CircuitPython's own
     jpegio.JpegDecoder decodes the same frame into a displayio.Bitmap (16-bit,
     documented RGB565_SWAPPED); the LVGL frame with each pixel's two bytes
     swapped must equal that bitmap row for row. This is D2 measured, not read.
     Odd widths (odd_size_37x29.jpg) are compared only left of the right-edge
     MCU column: CircuitPython's shared-module/jpegio/JpegDecoder.c
     bitmap_output() sets the source stride to `src_width / 2` uint32 words,
     which rounds an odd edge-block width down (5 px -> 4), so every row of
     that block after the first is read one pixel further left than it should
     be -- CP's own Bitmap is wrong there, the LVGL frame (== jpegio's golden,
     a straight jd_decomp) is right. Measured on 10.2.1: 104 pixels differ,
     all in columns 32..36, rows 1..28. An upstream CircuitPython bug, not
     the shim's; the test asserts that the difference stays inside that block.
  4. The image widget takes its size from the JPEG, not from the descriptor
     header: a descriptor with header w/h = 0 and cf UNKNOWN (which LVGL's
     built-in bin decoder refuses, so no other decoder can size it) still
     renders the full frame; the progressive and DHT-less frames stay 0x0.
  5. The C920e camera frame (SOI DQT SOF0 ..., not JFIF-first, DRI segment)
     decodes: the shim sniffs SOI only; LVGL's is_jpg() would have refused it.
  6. lv.deinit(); lv.init() re-registers the decoder (the frame decodes again),
     and a second lv.init() without deinit does not break it.
  7. File sources through lib/fs_driver.py (this repo's synced copy, put on
     sys.path): the C920e frame by its .jpg path, the same bytes copied to a
     temporary file WITHOUT an extension (the sniff is SOI-only for files too,
     the rule displayif's shim applies on MicroPython), both hashing to the
     golden digest; a non-JPEG file (the corpus README) stays 0x0.

Run with the unix CircuitPython built with CIRCUITPY_LVGL=1 and
CIRCUITPY_JPEGIO=1 (the coverage variant has both) against lvgl-bindings at the
commit in LVGL_BINDINGS_COMMIT, from this repo's root or the aggregator:

    bin/circuitpython tests/test_lvgl_jpeg_decode.py

Needs the displayif checkout as a sibling of this repo (frames at
../displayif/tests/jpegio/frames, resolved from this file's location) or
JPEGIO_FRAMES=/path/to/frames in the environment. Uses hashlib, binascii,
json, os, jpegio and displayio from the CircuitPython build. Pure-CPython
pytest collection skips this file: everything runs from main().
"""


def _frames_dir():
    import os

    env = os.getenv("JPEGIO_FRAMES") if hasattr(os, "getenv") else None
    if env:
        return env
    here = __file__.rsplit("/", 1)[0] if "/" in __file__ else "."
    return here + "/../../displayif/tests/jpegio/frames"


def _now():
    import time

    if hasattr(time, "ticks_ms"):  # unix CircuitPython has no time.monotonic
        return time.ticks_ms() / 1000.0
    return time.monotonic()


def _sha256_hex(buf):
    import binascii
    import hashlib

    return binascii.hexlify(hashlib.sha256(buf).digest()).decode()


def _swap_pairs(buf):
    out = bytearray(len(buf))
    for i in range(0, len(buf), 2):
        out[i] = buf[i + 1]
        out[i + 1] = buf[i]
    return out


class _Display:
    """Headless native-RGB565 display whose flushes land in a bytearray."""

    def __init__(self, lv, width, height):
        self.lv = lv
        self.width = width
        self.height = height
        self.frame = bytearray(width * height * 2)
        self.flushes = 0
        self.disp = lv.display_create(width, height)
        self.disp.set_flush_cb(self._flush)
        self.disp.set_color_format(lv.COLOR_FORMAT.RGB565)
        self.buf = lv.draw_buf_create(width, height, lv.COLOR_FORMAT.RGB565, 0)
        self.disp.set_draw_buffers(self.buf, None)
        self.disp.set_render_mode(lv.DISPLAY_RENDER_MODE.PARTIAL)

    def _flush(self, disp, area, color_p):
        w = area.x2 - area.x1 + 1
        h = area.y2 - area.y1 + 1
        raw = color_p.__dereference__(w * h * 2)
        for r in range(h):
            o = ((area.y1 + r) * self.width + area.x1) * 2
            self.frame[o : o + w * 2] = raw[r * w * 2 : (r + 1) * w * 2]
        self.flushes += 1
        disp.flush_ready()

    def clear(self):
        for i in range(len(self.frame)):
            self.frame[i] = 0xA5
        self.flushes = 0

    def crop(self, w, h):
        out = bytearray(w * h * 2)
        for r in range(h):
            o = r * self.width * 2
            out[r * w * 2 : (r + 1) * w * 2] = self.frame[o : o + w * 2]
        return out


def _image_dsc(lv, jpeg, w, h, cf=None):
    """A variable image source carrying JPEG bytes.

    cf RAW with the real w/h is the descriptor a user writes. cf UNKNOWN is the
    discriminating form for the negative checks: LVGL's built-in bin decoder
    accepts any variable descriptor except cf UNKNOWN (lv_bin_decoder_info), so
    with UNKNOWN only the jpegio decoder can give the widget a size.
    """
    if cf is None:
        cf = lv.COLOR_FORMAT.RAW
    return lv.image_dsc_t(
        {
            "header": {"w": w, "h": h, "cf": cf, "magic": lv.IMAGE_HEADER_MAGIC},
            "data_size": len(jpeg),
            "data": jpeg,
        }
    )


def _render(lv, display, dsc):
    """Draw dsc at (0, 0) of a fresh screen; return (w, h) the widget took."""
    scr = lv.obj()
    scr.set_style_pad_all(0, 0)
    scr.set_style_bg_color(lv.color_hex(0x123456), 0)
    lv.screen_load(scr)
    img = lv.image(scr)
    img.set_src(dsc)
    img.set_pos(0, 0)
    scr.update_layout()
    w, h = img.get_width(), img.get_height()
    display.clear()
    lv.refr_now(display.disp)
    assert display.flushes > 0, "flush_cb never ran"
    return w, h


def _cp_jpegio_bitmap_bytes(jpeg, w, h):
    """CircuitPython's jpegio -> displayio.Bitmap; rows without the bitmap's word padding."""
    import displayio
    import jpegio

    dec = jpegio.JpegDecoder()
    assert dec.open(jpeg) == (w, h), "jpegio.open size differs"
    bm = displayio.Bitmap(w, h, 65536)
    dec.decode(bm)
    raw = bytes(memoryview(bm))  # the view's items are uint16; bytes() gives the raw buffer
    stride_bytes = ((w * 16 + 31) // 32) * 4  # displayio stores rows in whole uint32 words
    assert len(raw) == stride_bytes * h, (len(raw), stride_bytes, h)
    out = bytearray(w * h * 2)
    for r in range(h):
        out[r * w * 2 : (r + 1) * w * 2] = raw[r * stride_bytes : r * stride_bytes + w * 2]
    return out


def main():
    import json

    import lvgl as lv

    t0 = _now()
    frames_dir = _frames_dir()
    with open(frames_dir + "/golden_tjpgd.json") as f:
        golden = json.load(f)["frames"]
    with open(frames_dir + "/reference.json") as f:
        sizes = json.load(f)["frames"]

    # 1. LVGL's own decoder is off on this target
    print("== 1. LV_USE_TJPGD is 0 on CircuitPython")
    assert not hasattr(lv, "tjpgd_init") and not hasattr(lv, "tjpgd_deinit"), "lv.tjpgd_init present: LVGL's TJPGD is on"
    print("lv.tjpgd_init / lv.tjpgd_deinit absent")

    lv.init()
    W, H = 320, 240
    display = _Display(lv, W, H)

    # 2 + 3 + 5. every decodable corpus frame at scale 0: golden digest, and CP jpegio's bitmap
    print("== 2/3/5. corpus frames through lv.image: golden digest, jpegio bitmap witness")
    names = sorted(n for n in golden if n in sizes)
    assert "c920e_320x240_dri.jpg" in names
    for name in names:
        with open(frames_dir + "/" + name, "rb") as f:
            jpeg = f.read()
        w, h = sizes[name]["width"], sizes[name]["height"]
        assert w <= W and h <= H, name
        got_w, got_h = _render(lv, display, _image_dsc(lv, jpeg, w, h))
        assert (got_w, got_h) == (w, h), "%s: lv.image is %dx%d, expected %dx%d" % (name, got_w, got_h, w, h)
        frame = display.crop(w, h)
        digest = _sha256_hex(frame)
        want = golden[name]["0"]
        status = "golden match" if digest == want else "GOLDEN MISMATCH (golden %s..)" % want[:16]
        witness = _cp_jpegio_bitmap_bytes(jpeg, w, h)
        swapped = _swap_pairs(frame)
        if w % 2 == 0:
            same = swapped == witness
            scope = "full width"
        else:
            # CP's bitmap_output mis-strides an odd-width right-edge MCU block
            # (see the module docstring): compare left of that block, and
            # require the mismatch to stay inside it.
            edge = w - (w % 16)
            same = all(swapped[(r * w) * 2 : (r * w + edge) * 2] == witness[(r * w) * 2 : (r * w + edge) * 2] for r in range(h))
            outside_edge = same
            inside_edge = any(swapped[(r * w + edge) * 2 : (r * w + w) * 2] != witness[(r * w + edge) * 2 : (r * w + w) * 2] for r in range(h))
            scope = "columns 0..%d (CP Bitmap edge block %d..%d %s, its own jpegio bug)" % (
                edge - 1, edge, w - 1, "differs" if inside_edge else "matches")
            assert outside_edge, "%s: LVGL and CP's Bitmap differ left of the right-edge MCU block" % name
        print("%-36s %3dx%-3d flushes %2d sha256 %s.. %s; bytes == jpegio bitmap (pair-swapped) over %s: %s" % (
            name, w, h, display.flushes, digest[:16], status, scope, same))
        assert digest == want, "%s: LVGL frame digest differs from jpegio's golden at scale 0" % name
        assert same, "%s: LVGL's decoded pixels are not jpegio's RGB565_SWAPPED words" % name

    # 4. the widget sizes itself from the JPEG, not from the descriptor header
    print("== 4. descriptor header w/h = 0")
    name = "odd_size_37x29.jpg"
    with open(frames_dir + "/" + name, "rb") as f:
        jpeg = f.read()
    got_w, got_h = _render(lv, display, _image_dsc(lv, jpeg, 0, 0, lv.COLOR_FORMAT.UNKNOWN))
    assert (got_w, got_h) == (37, 29), (got_w, got_h)
    assert _sha256_hex(display.crop(37, 29)) == golden[name]["0"]
    print("%s with a zeroed header (cf UNKNOWN): lv.image is 37x29 and the digest matches" % name)

    # refusals: the progressive frame and the DHT-less frame must not render (no crash)
    print("== refusals")
    for name, why in (("progressive_320x240.jpg", "SOF2"), ("nodht_320x240.jpg", "no DHT")):
        with open(frames_dir + "/" + name, "rb") as f:
            jpeg = f.read()
        # header says 320x240 but cf UNKNOWN: a size can only come from the jpegio decoder
        got_w, got_h = _render(lv, display, _image_dsc(lv, jpeg, 320, 240, lv.COLOR_FORMAT.UNKNOWN))
        assert (got_w, got_h) == (0, 0), "%s (%s) was accepted: %dx%d" % (name, why, got_w, got_h)
        print("%-36s refused (%s): lv.image stays 0x0, no crash" % (name, why))

    # 7. file sources: .jpg path, an extension-less copy, and a non-JPEG file
    print("== 7. file source through fs_driver: .jpg, extension-less copy, non-JPEG")
    import os
    import sys

    lib = (__file__.rsplit("/", 1)[0] if "/" in __file__ else ".") + "/../lib"
    if lib not in sys.path:
        sys.path.append(lib)
    import fs_driver

    fs_driver.register("S")
    name = "c920e_320x240_dri.jpg"
    with open(frames_dir + "/" + name, "rb") as f:
        jpeg = f.read()
    got_w, got_h = _render(lv, display, "S:" + frames_dir + "/" + name)
    assert (got_w, got_h) == (W, H), "file source %s: lv.image is %dx%d" % (name, got_w, got_h)
    assert _sha256_hex(display.crop(W, H)) == golden[name]["0"], "file source %s: digest differs" % name
    print("S:.../%s: %dx%d, digest matches" % (name, got_w, got_h))
    getenv = getattr(os, "getenv", None)
    tmp = ((getenv("TMPDIR") if getenv else None) or "/tmp") + "/lvgl_jpegio_noext_%d" % id(jpeg)
    with open(tmp, "wb") as f:
        f.write(jpeg)
    try:
        got_w, got_h = _render(lv, display, "S:" + tmp)
        assert (got_w, got_h) == (W, H), "extension-less copy not claimed: lv.image is %dx%d" % (got_w, got_h)
        assert _sha256_hex(display.crop(W, H)) == golden[name]["0"], "extension-less copy: digest differs"
    finally:
        os.remove(tmp)
    print("the same bytes as an extension-less file: %dx%d, digest matches (sniffed by SOI, not by name)" % (got_w, got_h))
    got_w, got_h = _render(lv, display, "S:" + frames_dir + "/README.md")
    assert (got_w, got_h) == (0, 0), "a non-JPEG file was claimed: %dx%d" % (got_w, got_h)
    print("a non-JPEG file (README.md) is not claimed: 0x0")

    # 6. deinit / init re-registers; a second init is harmless
    print("== 6. lv.deinit(); lv.init() and a repeated lv.init()")
    name = "baseline_jfif_64x48.jpg"
    with open(frames_dir + "/" + name, "rb") as f:
        jpeg = f.read()
    lv.deinit()
    lv.init()
    lv.init()
    display = _Display(lv, W, H)
    got_w, got_h = _render(lv, display, _image_dsc(lv, jpeg, 64, 48))
    assert (got_w, got_h) == (64, 48), (got_w, got_h)
    assert _sha256_hex(display.crop(64, 48)) == golden[name]["0"]
    print("decoder registered again after deinit/init (and init twice): %s digest matches" % name)

    print("lvgl jpeg decode tests passed: %d frames, %.2f s" % (len(names), _now() - t0))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
