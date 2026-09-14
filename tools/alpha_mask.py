"""Clamp an upscaled image's alpha to the stock silhouette.

The upscaler adds a faint alpha haze around every sprite (cursor_circle: 27% of texels at alpha 1-16
against 10% in stock). Sprites that stack, like the 24 cursor trail samples, turn that haze into a
visible halo. This zeroes 4x alpha everywhere the stock alpha, dilated by one stock texel, is zero.

  python tools/alpha_mask.py <stock @2x.png> <upscaled 4x.png> [out.png]     (in place without out)
  python tools/alpha_mask.py --tree <stock res dir> <res dir with @4x files>  (whole tree, in place)
"""
import sys, pathlib
import numpy as np
from PIL import Image

def mask_alpha(stock_rgba: np.ndarray, up_rgba: np.ndarray) -> tuple[np.ndarray, int]:
    """Zero the upscaled alpha wherever the stock alpha, dilated by one stock texel, is zero. Only
    texels outside the stock silhouette change: soft gradients inside it (shadows, glows) keep the
    model's smooth values. (A clamp to the stock 3x3 maximum was tried: it quantises gradients into
    2x2 stair steps that show as pixelated shading.)"""
    a = stock_rgba[..., 3] > 0
    d = a.copy()
    d[1:, :] |= a[:-1, :]; d[:-1, :] |= a[1:, :]; d[:, 1:] |= a[:, :-1]; d[:, :-1] |= a[:, 1:]
    d[1:, 1:] |= a[:-1, :-1]; d[:-1, :-1] |= a[1:, 1:]; d[1:, :-1] |= a[:-1, 1:]; d[:-1, 1:] |= a[1:, :-1]
    sy = up_rgba.shape[0] // a.shape[0]; sx = up_rgba.shape[1] // a.shape[1]
    m = np.repeat(np.repeat(d, sy, axis=0), sx, axis=1)
    m = np.pad(m, ((0, up_rgba.shape[0] - m.shape[0]), (0, up_rgba.shape[1] - m.shape[1])), constant_values=True)
    out = up_rgba.copy(); kill = (~m) & (out[..., 3] > 0)
    out[..., 3][kill] = 0
    return out, int(kill.sum())

def bleed_rgb(rgba: np.ndarray, iterations: int = 8) -> np.ndarray:
    """Copy edge colours outward into fully transparent texels (alpha 0), one texel per iteration, so
    mipmap averaging and bilinear filtering never mix in a wrong colour at sprite edges."""
    out = rgba.copy(); a = out[..., 3] > 0
    for _ in range(iterations):
        if a.all(): break
        rgb = out[..., :3].astype(np.uint16); cnt = a.astype(np.uint16)
        acc = np.zeros_like(rgb); n = np.zeros_like(cnt)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            sr = np.roll(rgb, (dy, dx), axis=(0, 1)); sa = np.roll(cnt, (dy, dx), axis=(0, 1))
            acc += sr * sa[..., None]; n += sa
        fill = (~a) & (n > 0)
        out[..., :3][fill] = (acc[fill] // n[fill][:, None]).astype(np.uint8)
        a = a | fill
    return out

def process(stock_path: pathlib.Path, up_path: pathlib.Path, out_path: pathlib.Path) -> int:
    s = np.asarray(Image.open(stock_path).convert('RGBA')); u = np.asarray(Image.open(up_path).convert('RGBA'))
    if s.shape[0] * 2 != u.shape[0] or s.shape[1] * 2 != u.shape[1]: return -1
    if not (s[..., 3] == 0).any(): return 0            # fully opaque: nothing to mask
    out, n = mask_alpha(s, u)
    out = bleed_rgb(out)
    Image.fromarray(out).save(out_path)
    return n

if __name__ == '__main__':
    args = sys.argv[1:]
    if args and args[0] == '--tree':
        stock, res = pathlib.Path(args[1]), pathlib.Path(args[2]); total = files = 0
        for q in res.rglob('*@4x.png'):
            p = stock / q.relative_to(res).parent / q.name.replace('@4x.png', '@2x.png')
            if not p.exists(): continue
            n = process(p, q, q)
            if n > 0: total += n; files += 1
        print(f'{files} files changed, {total} texels cleared')
    else:
        n = process(pathlib.Path(args[0]), pathlib.Path(args[1]), pathlib.Path(args[2] if len(args) > 2 else args[1]))
        print(f'{n} texels cleared')
