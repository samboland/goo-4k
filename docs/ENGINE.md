# Engine notes

Reverse-engineering reference for World of Goo, Steam Win64 build 20824155 (17 Nov 2025),
`WorldOfGoo.exe` 3,653,120 bytes, image base 0x140000000. All addresses are stock virtual
addresses. `FUN_` names are Ghidra's.

## Engine facts

- **Assets.** Manifests reference images without extension. With `use_2x_assets` the loader
  (`FUN_1400bb010`) appends `@2x.png` and falls back to `.png`; only `@2x.png` files ship (2123).
  Image scale is a constant chosen by a flag, not derived from image size: `FUN_1400d7a20` stores
  0.5f (`DAT_1402af500`) for the flagged path, else 1.0f (`DAT_1402aeb40`). Textures are padded to
  a square power of two (`w*w*4` bytes): a 4096x1860 image becomes a 64 MB texture.
- **Main loop.** `FUN_1400ae960` renders whenever at least 1 ms passed; the only limiter is vsync.
  `FUN_1400aeb70` runs simulation ticks at 50 per second (`mov $0x32,%edx` at 0x1400ab236;
  setter `FUN_1400adf90` stores ups at env+0x138 and 1000/ups ms at +0x13c).
- **Simulation.** Physics is ODE. `Scene::tick(scene, float time, float dt, bool)` =
  `FUN_14009af30` steps the world (`World::tick` `FUN_140206400` on `scene+0xe0`, then
  `dWorldQuickStep`) and ticks every scene object. dt is the `Wog` time scale in tick units.
  Per-call controllers (walking goo, camera mover, cursor spring) ignore dt, so raising the tick
  rate with a scaled dt breaks them (tried and abandoned; see below).
- **Wog singleton** (`FUN_14008c9c0`, 0x138 bytes): +0x10 Model, +0x24 clock base, +0x50 time
  scale (1.0; 0 when paused), +0x54 float tick counter. `Wog::time()` = `FUN_14008a920` =
  base + counter / ups * scale. `Wog::tick` = `FUN_14008f3f0` = `Wog::vftable` (0x1402b5af0)
  + 0x30; it bumps the counter by 1.0 and runs the game tick. `WogRenderer::vftable` at
  0x1402b5f38: +8 draw `FUN_1400933c0`, +0x10 effects pass `FUN_140094480`.
- **Model** (Wog+0x10): +0x18 state (1: level at +0xb0, 3: +0xc0, 4/5: +0xb8); scenes +0x90,
  +0xa0, overlay +0x98; cursors +0x2e0 (x4). `Model::getCamera` = `FUN_140057870`,
  `Model::getLevel` = `FUN_140057a30`. Level: scenes +0x178 and +0x140.
- **Bodies.** `PhysBoy::Body` holds a `BoyLib::Positionable` at +0x10: dirty byte +0x18, local
  position +0x28/+0x2c, rotation +0x30, parent +0x38. ODE body pointer at +0x58; the post-step
  copies ODE position into the Positionable. World body list at world+0x10, count at
  world+0x8010. Renderers (goo balls, strands, geometry) read through the Positionable.
- **Camera.** `Boy::Camera` is a Positionable at +0: dirty +8, position +0x18/+0x1c, zoom +0xb8.
- **Cursor.** `GooCursor` keeps 24 trail samples shifted per tick by `FUN_140025fa0`; the head
  sample is at +0x28/+0x2c.
- **Animations.** Clock-driven animations (`SinAnim` etc.) are applied at draw time against
  `Wog::time()` (call sites 0x14001f45b, 0x14001f499 in the scene object draw, 0x14002b1b0 in
  `ImageDrawable`). Keyframe animations go through `FUN_140029e10(anim, float t, float t0,
  graphics)`; callers hold a per-tick progress value (tooltip: +0xb8, 0.01 per tick up to 0.2).
  Particle effects (`SimpleParticleEffect` etc.) are per-tick and read `Wog::time` during draw;
  the effects factory is `FUN_140017690` / `FUN_1400175d0(factory, string* outId, string* name,
  float depth)`, and `EffectLauncher::tick` adds the effect with `FUN_140098870(scene, effect)`.
- **Window.** Fullscreen already uses `SDL_WINDOW_FULLSCREEN_DESKTOP` (0x1001); the toggle
  persists `fullscreen,true|false` into `pers3.dat`. The game sets system DPI awareness. The
  bundled SDL2.dll is 2.0.9, which minimizes fullscreen windows on focus loss by default.
- **Config.** `%LOCALAPPDATA%\2DBoy\WorldOfGoo\config.ini`: `vsync` (-1/0/1), `use_fbo`,
  `fbo_width`, `fbo_height`, `screen_width`, `screen_height`. Undocumented keys read by the exe:
  `max_aspect_ratio`, `fullscreen`.

## Patches (tools/interp/build.py, applied by the installer)

In place, 123 bytes:

| Site | Change |
| --- | --- |
| PE header | section count 7 -> 8, `.goo` section header (RVA 0x398000, 0x4000, RWX), SizeOfImage |
| 0x1400d7c6d+4 | flagged scale reads 0.25f (`DAT_1402b0ba8`) instead of 0.5f |
| 0x1400d7c77+4 | fallback scale reads 0.5f (`DAT_1402af500`) instead of 1.0f |
| 0x1402b8370 | string `@2x.png` -> `@4x.png` |
| 0x1400bb34b, 0x1400bb79a, 0x1400bb97d | fallback suffix pointer `.png` -> `@2x.png` in `.goo`; lengths at 0x1400bb342/0x1400bb791 and 0x1400bb355/0x1400bb7a4 go 4 -> 7 |
| 0x14004ea6e, 0x14004ea9f, 0x140061597, 0x1400615cf, 0x140061d9a | `call Scene::tick` -> `tramp` |
| Wog::vftable+0x30, WogRenderer::vftable+8, +0x10 | `tick_hook`, `draw_hook`, `fx_hook` |
| 0x14008a920 | `Wog::time` entry -> `jmp time_hook` (function fully replaced) |
| 0x140029e10 | keyframe evaluator entry -> `jmp anim_hook` (11-byte prologue relocated) |

Appended: the `.goo` section (about 11 KB) from `cave.s`:

- `tramp`: records the scene's world for this tick and copies every body's position and
  rotation into a 1 MB buffer (8 worlds x 4096 bodies x 32 bytes, allocated with the game's
  `operator new` on first use). Per-world snapshot counts limit later interpolation to bodies that
  existed at snapshot time.
- `tick_hook`: clears the world list, bumps a tick counter, stores `QueryPerformanceCounter`,
  snapshots the camera position, and runs the F5 debug spawn when requested.
- `draw_hook`: alpha = clamp((now - tick) * 50 / freq, 0, 1). Writes prev + (cur - prev) *
  alpha into every body still at its snapshot slot (skipped when a body moved more than 200 px or
  rotated more than 3 rad in one tick, which means slot reuse or an angle wrap), the camera, and
  the live mouse position into each cursor head; sets dirty bytes; calls the stock draw; restores.
- `time_hook`: stock formula, plus alpha ticks only while inside draw and only for the three
  animation call sites. Every other reader sees tick-exact time.
- `anim_hook`: per animation object, remembers the last two tick values and the tick they
  changed; while drawing, interpolates `t = last - (1 - alpha) * rate`. Holds when the rate jumps
  more than 0.15 per tick (restart or loop wrap), when the value changes within a tick
  (clock-driven, already smooth), when the entry was not drawn for two ticks (object went away),
  and for the particle-effect call site (0x140003762).
- Data markers read or written by the shim: `GOO4K:` build stamp, `GOO4KFLAGS` (+12: feature
  mask), `GOO4KDEBUG` (+12: command/status word).

SDL2.dll (`tools/sdl2_patch.py --no-minimize`): one byte at 0x6c7f58a1, the default of
`SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS`, 1 -> 0. The `--short` option (fullscreen window one row
shorter than the display via a cave at 0x6c839358) is kept but unused.

## Presentation shim (tools/present)

Proxy `SDL2.dll`; 653 exports forward to `SDL2_real.dll`; `SDL_GL_SwapWindow`,
`SDL_GL_SetSwapInterval`, `SDL_GL_GetSwapInterval` are intercepted. First swap: D3D11 device with
BGRA support, `CreateSwapChainForHwnd` on the GL window (BGRA8, 3 buffers, FLIP_DISCARD,
ALLOW_TEARING when supported, NO_ALT_ENTER), `wglDXOpenDeviceNV`, a shared D3D11 texture
registered to a GL texture. Per frame: lock, `glBlitFramebuffer` from the window back buffer
(Y flipped) into the shared texture, unlock, optional Direct2D overlay, `CopyResource` to buffer
0, `Present(interval == 0 ? 0 : 1, tearing flag when 0)`. Client size changes call
`ResizeBuffers`. Env `GOO_PRESENT_OFF=1` falls back to the GL swap. PresentMon reports
"Hardware: Independent Flip" for both synced and unsynced modes.

## Findings from comparing with stock

- Eruption particle flashes came from the advanced clock pushing particles past their lifetime
  for one frame; fixed by the call-site whitelist in `time_hook`.
- Intro hands flash came from a restarted keyframe animation producing a negative time; fixed by
  the rate guard, the zero clamp, and the continuous-value detection in `anim_hook`.
- The held goo ball spin on the title screen exists in stock.
- Special K attaches to the shim's swapchain; its HDR retrofit works.

## Abandoned: high tick rate

Running the simulation at 100 or 250 ticks with dt scaled by 50/ups kept gravity and collisions
correct but ran every per-call controller at the tick multiple (walking goo, camera panning,
cursor spring), and timers converted from seconds to ticks ran slow. A physics-only intermediate
tick variant fixed some and not others. Interpolation replaced it; the code was removed.

## Asset batch

Chain: StarSample 2x with median and curvature blur, alpha carried through the model, forced 2x
(`tools/run_chain_batch.py --scale 2`, final node the last blur). Inputs are staged flat with path
segments joined by `__` and the `@2x` suffix stripped; `report.json` in the output folder is the
resumable progress record; `tools/install_4x.py` copies results into a `res` tree as `@4x.png`
and duplicates tile sidecars. The stock 2x set is 481 megapixels; the model runs at roughly 51
seconds per megapixel on an RTX 4080, about 7 hours in total. Auto tile size; 1024 px tiles
overflow 16 GB of VRAM with this model.
