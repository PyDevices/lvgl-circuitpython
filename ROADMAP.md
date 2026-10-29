# Roadmap

- CI that builds a CircuitPython port with lvgl and runs the tests on it.
- An `examples/` folder, starting with `lvgl_simpletest.py`.
- `lvgl_circuitpython.__revision__`, naming the commit your firmware built,
  as lvgl-micropython's `lvgl_micropython.__revision__` does.
- `LVGL_BINDINGS_COMMIT` becomes `DEPENDENCIES.lock`, the pin file every
  PyDevices repository uses: a dependency, its URL and its full commit a line.

Otherwise work here follows bug reports and requests, so if something is
broken or missing for you, open an
[issue](https://github.com/PyDevices/lvgl-circuitpython/issues).
