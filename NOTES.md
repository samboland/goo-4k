# goo-4k notes

Target: World of Goo (Steam build 20824155, 2025-11-17, Win64). Display 2560x1440 @ 240 Hz.

## Engine facts (from Ghidra on WorldOfGoo.exe)

- Manifests reference images without extension. With `use_2x_assets`, the loader appends `@2x.png` and falls back to `.png`. Only `@2x.png` files ship (2123).
- Image scale is a constant, not derived from image size: `FUN_1400d7a20` stores 0.5f (from `DAT_1402af500`) when loaded with the 2x flag, else 1.0f.
- Textures are padded to a square power of two (`w*w*4` bytes). A 4096x1860 image becomes a 64 MB texture.
- Main loop `FUN_1400ae960` renders whenever >= 1 ms passed. No frame limiter besides vsync. 240 fps confirmed with `vsync = 0`.
- Simulation ticks at 50 ups: `mov $0x32,%edx; call *0x60(%rax)` at `0x1400ab236` (config init). Setter `FUN_1400adf90` stores ups at +0x138 and 1000/ups ms at +0x13c.
- Physics is ODE. `Scene::tick(scene, float time, float dt, bool)` at `FUN_14009af30` steps the world (`World::tick` `FUN_140206400` on `scene+0xe0`) then ticks every scene object. dt comes from the `Wog` singleton field +0x50 (time scale, 1.0; 0 = paused), in tick units. Changing the tick rate alone runs the game faster: the user confirmed 100 ups = 2x speed.
- `Wog` singleton (`FUN_14008c9c0`, 0x138 bytes): +0x10 Model, +0x24 clock base, +0x50 time scale, +0x54 float tick counter. `Wog::time()` `FUN_14008a920` = base + counter / ups * scale. Real time, ups-aware.
- `Wog::tick` = `FUN_14008f3f0` = `Wog::vftable` (0x1402b5af0) + 0x30. It bumps the counter by 1.0 and runs the whole game tick.
- `Model` (Wog+0x10): +0x18 state (1: level at +0xb0, 3: +0xc0, 4/5: +0xb8), scenes +0x90, +0xa0, overlay +0x98, cursors +0x2e0 (x4). Level: scenes +0x178 and +0x140, +0x390 = skip flag. `FUN_1400508d0(level, before)` syncs dragged goo with cursors around the step.
- Time-based animations (SinAnim etc.) are applied in the renderer against `Wog::time()`, so they are smooth at any fps. Cursor trail (`GooCursor`, 24 samples shifted per tick by `FUN_140025fa0`) and scene object ticks are per-tick.
- Fullscreen already uses `SDL_WINDOW_FULLSCREEN_DESKTOP` (0x1001). Toggle persists `fullscreen,true|false` into `pers3.dat`.
- Shipped SDL2.dll is 2.0.9. It minimizes fullscreen windows on focus loss by default.

## Patches (applied in work/sandbox only)

| File | VA / file offset | Original | Patched | Effect |
| --- | --- | --- | --- | --- |
| WorldOfGoo.exe | 0x1400d7c6d+4 / 0xd7071 | `8b 78 1d 00` | `33 8f 1d 00` | 2x-flag scale reads 0.25f (`DAT_1402b0ba8`) instead of 0.5f. Requires all `@2x` files at 4x native. |
| SDL2.dll | 0x6c7f58a1 / 0xb4ca1 | `01` | `00` | `SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS` defaults to 0. Fullscreen stays up on alt-tab. |

Also: `steam_appid.txt` (22000) next to the exe so a copy does not relaunch through Steam.

### High tick rate (tools/tickpatch)

`build.py SRC DST --ups N` (N a multiple of 50). It grows the `.text` raw data by 0x200 so the section tail (0x1402add10..0x1402ae000) can hold `cave.s`, then:

- sets the ups byte at `0x1400ab237` (stock 0x32),
- routes the five `Scene::tick` call sites through `tramp`, which multiplies dt by 50/ups,
- points `Wog::vftable+0x30` at `new_tick`.

`new_tick` counts ticks in a zero-filled dword at `0x14036d4c0` (.data tail). Every (ups/50)th tick it tail-calls the stock `Wog::tick`. On the other ticks it: bumps the clock counter, refreshes each cursor's head sample (+0x28/+0x2c) from the input device without shifting the trail, and steps only the physics worlds (level scenes +0x178/+0x140 with the sync calls, model scenes +0x90/+0xa0, overlay +0x98 with dt = 50/ups). Scene objects, input, Tickables, timers all stay at 50 Hz. The first build wrote the counter into `.text` and crashed; the second ticked scene objects on every tick and ran menu text at 2.5x.

Variants in work/sandbox/Win64: `WorldOfGoo-ups100.exe`, `WorldOfGoo-ups250.exe`. Confirmed by Sam on 2026-09-10: goo physics at normal speed, intro at normal speed, cursor smooth at proper speed.

## Config (%LOCALAPPDATA%\2DBoy\WorldOfGoo\config.ini)

`vsync = 0`, `use_fbo = 1`, `fbo_width = 2560`, `fbo_height = 1440`. Backup in work/.

## Upscale test

work/test-set-01: ten assets through ui-redraw `upscalingtest_01.chn` (StarSample 2x) and `upscalingtest_02.chn` (PBRify 4x DAT2) at forced 2x. Review: work/test-set-01/compare.html. Runner: tools/run_chain_batch.py (adds `--scale`, resolves passthrough nodes). Backend: chaiNNer python `run.py 8767 --storage-dir work/backend`.

### Render interpolation (tools/interp) - current approach

The high-tick-rate approach broke every per-call controller (walking goo, camera, cursor spring at 5x) and the chapter card (5x slow). Replaced by interpolation: simulation and tick rate stay stock.

`build.py SRC DST` appends an RWX section `.goo` at 0x140398000 with `cave.s` and installs:

- five `Scene::tick` call sites -> `tramp`: records the scene's world for this tick and copies every body's cached position (+0x28/+0x2c) and rotation (+0x30) into a 1 MB buffer (8 worlds x 4096 bodies x 32 bytes, allocated with the game's operator new on first use).
- `Wog::vftable+0x30` -> `tick_hook`: clears the world list, stores QueryPerformanceCounter, snapshots the level camera position (+0x18/+0x1c).
- `WogRenderer::vftable+8` -> `draw_hook`: alpha = (now - tick) * 50 / freq clamped to [0,1]; writes prev + (cur - prev) * alpha into every body still at its snapshot slot, the camera, and the live mouse position into each cursor head sample; sets the positionable dirty byte; calls the stock draw; restores everything.
- `Wog::time` (`FUN_14008a920`) start -> `jmp time_hook`: same formula as stock, plus alpha ticks while inside draw, so clock-driven animations (SinAnim text) advance per frame.

Layout facts used: PhysBoy::Body has a BoyLib::Positionable at +0x10 (dirty +0x18, local pos +0x28/+0x2c, rotation +0x30, parent +0x38); World body list at world+0x10, count at world+0x8010; Scene world at scene+0xe0; Camera is a Positionable at +0 (dirty +8, pos +0x18/+0x1c, zoom +0xb8); Model::getCamera = `FUN_140057870`.

Output: work/sandbox/Win64/WorldOfGoo-interp.exe. Runs past the intro; gameplay not yet verified.
