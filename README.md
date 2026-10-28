![A blue button reading Hello from LVGL on a light gray background](docs/images/hello.png)

# lvgl-circuitpython

lvgl-circuitpython is the part of OmniPython that builds LVGL into CircuitPython-compatible firmware as a user C module, so `import lvgl as lv` works on CircuitPython 11.

CircuitPython 11 builds user C modules the way MicroPython does, so you hand this directory to a port's `make`; nothing in the CircuitPython tree changes:

```bash
git clone https://github.com/PyDevices/lvgl-circuitpython
make -C circuitpython/ports/unix USER_C_MODULES=/path/to/lvgl-circuitpython
```

On a board, add `CIRCUITPY_GIFIO=0` to the same line. The build fetches the matching LVGL bindings itself; you need only `git`.

```python
import lvgl as lv

lv.init()
disp = lv.display_create(240, 120)
disp.set_color_format(lv.COLOR_FORMAT.RGB565)
buf = bytearray(240 * 120 * 2)
disp.set_buffers(buf, None, len(buf), lv.DISPLAY_RENDER_MODE.FULL)
flushed = []
disp.set_flush_cb(lambda d, area, px: (flushed.append(area.get_width()), d.flush_ready()))

button = lv.button(lv.screen_active())
button.center()
label = lv.label(button)
label.set_text("Hello from LVGL")
button.add_event_cb(lambda e: print("clicked"), lv.EVENT.CLICKED, None)
button.send_event(lv.EVENT.CLICKED, None)

lv.tick_inc(50)
lv.refr_now(disp)
print(label.get_text(), "- drew", flushed[-1], "px wide")
```

```text
clicked
Hello from LVGL - drew 240 px wide
```

The picture at the top is the frame that program drew.

[Docs](https://github.com/PyDevices/lvgl-bindings/blob/main/docs/get-started/install.md#circuitpython-compatible-firmware-with-lvgl-circuitpython) · [Examples](https://pydevices.github.io/gallery/pyscript/) · [Roadmap](ROADMAP.md)

OmniPython is made by [PyDevices](https://pydevices.com).
