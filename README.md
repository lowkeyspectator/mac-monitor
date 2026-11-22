# Mac Monitor

A small native macOS system monitor written in SwiftUI. It shows CPU, GPU, memory and storage usage in a floating widget, a detailed view and the menu bar.

## Features

- **Widget view:** a compact floating window with rings for CPU, GPU, RAM and disk, plus a bar that splits memory into CPU/apps, GPU and free.
- **Detailed view:** total and per-core CPU usage with history graphs, GPU utilisation (device, renderer and tiler), a full memory breakdown (app, wired, compressed, cached, free, swap and pressure) and every mounted volume.
- **Menu bar item:** live CPU and GPU percentages, with shortcuts to open either view.
- You can pin the window above other windows and drag it from anywhere.

It uses only public macOS APIs (`host_processor_info`, `host_statistics64`, `sysctl` and IOKit's `IOAccelerator` performance statistics). It needs no root access and no helper tools.

### About the CPU and GPU memory split

Apple Silicon Macs have unified memory: the CPU and GPU share one pool of RAM. The GPU figure is the memory the graphics driver reports as in use. That memory is already counted in wired and app memory, so the CPU figure is everything else that's in use.

## Requirements

- macOS 14 or later (tested on Apple Silicon)
- The Xcode Command Line Tools (`xcode-select --install`). The full Xcode app isn't needed.

## Build and run

```bash
./build.sh
open MacMonitor.app
```

`build.sh` compiles `Sources/*.swift` with `swiftc`, wraps the binary in an app bundle and signs it ad hoc. To keep the app, move `MacMonitor.app` to `/Applications`.

## Status

This is a small prototype. If you want a mature, full-featured monitor, try [Stats](https://github.com/exelban/stats), which is open source.
