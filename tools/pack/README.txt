goo-4k for World of Goo (Steam, Windows, build 20824155 / 17 Nov 2025)

What it does
- Renders at your display's native resolution with 4x-native art (texture pack).
- Smooth motion at any refresh rate: the simulation stays the stock 50 Hz and the
  drawn positions are interpolated per frame.
- Presents through a DirectX flip-model swapchain: instant alt-tab in borderless
  fullscreen, works with VRR and DirectX overlays.

Install
1. Close the game.
2. If you have the texture pack zip, extract it so that a "textures" folder sits next
   to install.cmd (install.cmd, textures\res\... ).
3. Run install.cmd. It finds the Steam install, checks the files are the expected build,
   backs up WorldOfGoo.exe and SDL2.dll into goo4k-backup, patches them, and sets the
   framebuffer to your display size and vsync to adaptive in the game config.
4. Launch from Steam as usual.

Remove: run uninstall.cmd. Steam's "verify integrity" also restores the stock exe and
SDL2.dll (textures stay, they are extra files); rerun install.cmd afterwards.

Options (file %LOCALAPPDATA%\2DBoy\WorldOfGoo\goopresent.ini, one per line)
  fps_cap=236     frame cap (VRR setups); 0 or absent = none
  overlay=1       show the build stamp at the top left
  interp=31       bitmask of interpolation features (1 bodies, 2 clock, 4 anims, 8 camera, 16 cursor)
  debug=1         enables F5, which spawns an unlock-burst effect at the camera (testing aid)
Log: %LOCALAPPDATA%\2DBoy\WorldOfGoo\goopresent.log
