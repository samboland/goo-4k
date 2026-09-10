# goo-4k

Native-resolution rendering, 4x-native art, and high-refresh motion for the Steam release of
**World of Goo** (2019 remaster, Win64). Tested on build 20824155 (17 Nov 2025) at 3840x2160 @ 240Hz.

This project is not affiliated with 2D Boy or Tomorrow Corporation. The repository contains no game files in and of itself.

## What it does

- **Native framebuffer:** The game renders into an offscreen framebuffer; the installer sets it
  to your display size instead of the stock 1600x900.
- **4x-native art:** A texture pack of every shipped image, upscaled 2x from the remaster's own
  2x assets with .derpy's [StarSample](https://openmodeldb.info/models/2x-StarSample-V2-HQ) model. The loader is patched to read `name@4x.png` when present
  and fall back to the stock `name@2x.png`, so the pack is purely additive.
- **Smooth motion at any refresh rate:** The simulation stays at the stock 50 Hz, bit-for-bit.
  Between ticks, drawn positions of every physics body, the camera, the cursor and the
  clock-driven and keyframe animations are interpolated by the frame's sub-tick fraction.
- **Modern presentation:** A proxy `SDL2.dll` presents the OpenGL frame through a DirectX 11
  flip-model swapchain (`WGL_NV_DX_interop2`). VRR,
  tearing-free vsync, and DirectX overlays such as Special K (HDR retrofit confirmed working).
- **No black screen on Alt + Tab:** Instant alt-tab in borderless fullscreen. The bundled SDL 2.0.9 default is patched.

## Install

Requirements: the current Steam build of World of Goo on Windows 10/11 and a GPU with D3D11 (and the
`WGL_NV_DX_interop2` extension which NVIDIA, AMD and Intel all provide by default)

Close the game, open PowerShell, and run:

```
irm https://raw.githubusercontent.com/samboland/goo-4k/main/get.ps1 | iex
```

It downloads the latest release, locates the Steam install, verifies the files are the expected
build, backs up `WorldOfGoo.exe` and `SDL2.dll` to `goo4k-backup`, patches them, installs the
shim and the texture pack, and sets the framebuffer and vsync lines in the game config. Then
launch from Steam as usual. Options go through a scriptblock:

```
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/samboland/goo-4k/main/get.ps1))) -NoTextures
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/samboland/goo-4k/main/get.ps1))) -Uninstall
```

Offline: download the installer zip and the texture pack zip from Releases, extract the
installer, put the pack's `textures` folder next to `install.cmd`, and run `install.cmd`.
`uninstall.cmd` restores the backups and removes the installed textures.

Steam's "verify integrity of game files" restores the stock exe and SDL2.dll (the textures are
extra files and stay); rerun the installer afterwards.

### Options

`%LOCALAPPDATA%\2DBoy\WorldOfGoo\goopresent.ini`, one `key=value` per line:

| Key | Default | Meaning |
| --- | --- | --- |
| `fps_cap` | 0 | Frame cap for VRR setups, e.g. `236` on a 240 Hz panel. 0 = none. |
| `overlay` | 0 | `1` shows the build stamp at the top left. |
| `interp` | 31 | Bitmask of interpolation features: 1 bodies, 2 clock, 4 keyframe animations, 8 camera, 16 cursor. |
| `debug` | 0 | `1` enables F5, which spawns an unlock-burst effect at the camera (testing aid). |

Game config (`config.ini` in the same folder): `vsync = -1` is adaptive (synced present, no
tearing), `0` is uncapped with tearing allowed, `fbo_width`/`fbo_height` set the render size.
The shim writes `goopresent.log` next to these files.

## How it works

The exe is changed in 123 bytes at 18 places (header, five call redirects, three vtable slots,
two function entries turned into jumps, and the loader's suffix strings and scale constants) plus
an 11 KB section appended with the new code. Everything else lives in the proxy DLL.

- **Loader.** The remaster's loader appends `@2x.png` and stores a fixed 0.5 scale for such
  images. The patch makes the first attempt `@4x.png` at 0.25 and the fallback `@2x.png` at 0.5.
- **Interpolation.** A trampoline on the five `Scene::tick` call sites snapshots every body's
  cached position before the world steps. A hook on the renderer's draw computes the sub-tick
  fraction from the performance counter, writes blended positions into the bodies, camera and
  cursor, advances the game clock for the three animation call sites, calls the stock draw, then
  restores everything. A detour on the keyframe evaluator interpolates per-tick animation
  progress. Nothing the simulation reads is ever left modified.
- **Presentation.** The proxy `SDL2.dll` forwards 653 exports to the renamed stock DLL and
  intercepts the swap. On the first swap it creates a D3D11 device and a flip-model swapchain on
  the game window and registers a shared texture with the GL context. Each frame it blits the GL
  back buffer into that texture, copies it to the swapchain and presents. The GL swap never runs.
- **Assets.** Every `@2x.png` goes through a chaiNNer chain (StarSample 2x, median and
  curvature blur) at forced 2x. The result reads as a clean, modern cartoon; the model removes the
  original's grain. A textured variant pack is possible later without code changes.

`docs/ENGINE.md` has the reverse-engineering notes: engine layout, addresses, the hook list, and
the findings from comparing against stock.

## Building from source

Prerequisites: Python 3, MSYS2 UCRT64 with `gcc`, `binutils` (`as`, `ld`, `objcopy`, `nm`) on
the PATH, and the stock game files. Ghidra was used for the analysis but is not needed to build.

```
sh tools/present/build.sh                                # proxy SDL2.dll (shim)
python tools/pack/build_pack.py [--textures <batch out dirs>]
```

`build_pack.py` applies the asset-scale patch to the stock exe, runs `tools/interp/build.py`
(assembles `cave.s`, appends the `.goo` section, installs the hooks), patches the stock SDL2.dll
with `tools/sdl2_patch.py --no-minimize`, diffs stock against patched into manifests, and writes
`dist/goo4k-<version>/` with the installer scripts. With `--textures` it also writes the texture
pack zip from batch output directories.

Asset pipeline: `tools/run_chain_batch.py` drives a saved chaiNNer chain through a headless
chaiNNer backend over a flat input folder; `tools/install_4x.py` copies finished outputs into a
`res` tree as `@4x.png` files. See `docs/ENGINE.md` for the batch procedure.

## Repository layout

```
tools/interp/    cave.s (hooks, assembled into the .goo section) and build.py (patches the exe)
tools/present/   shim.cpp, SDL2.def, build.sh (proxy SDL2.dll with DXGI presentation)
tools/pack/      installer scripts, manifest generator, pack builder
tools/sdl2_patch.py       SDL2.dll patches (no-minimize; optional one-row-short fallback)
tools/run_chain_batch.py  chaiNNer batch runner    tools/install_4x.py  @4x installer
tools/make_compare.py     side-by-side review page for upscale tests
docs/ENGINE.md   reverse-engineering notes and addresses
```

## Known limitations

- Particle effects and the cursor trail samples update at the stock 50 Hz by design.
- Interpolated positions lag the simulation by one tick (20 ms); the simulation itself is unchanged.
- 4x textures are padded to square power-of-two sizes by the engine; a 4096-wide background is a
  64 MB texture. Expect roughly 1 GB of VRAM in busy levels.
- The patches are byte-exact for build 20824155. A game update needs new offsets.

## License

MIT, see `LICENSE`. It covers the tools, patches, shim and documentation in this repository.
World of Goo, its engine and its art belong to 2D Boy and Tomorrow Corporation and are not
covered; the texture pack is a derivative of their art and is distributed separately.

## Credits

World of Goo by 2D Boy; the remaster by Tomorrow Corporation. Upscaling model:
[2x StarSample V2 HQ](https://openmodeldb.info/models/2x-StarSample-V2-HQ) by .derpy. Built with
chaiNNer, Ghidra, MinGW-w64 and PresentMon.

This repository was developed with the help of Claude Fable 5.1.

Copyright (c) 2026 Sam Boland