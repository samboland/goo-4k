"""Clamp an upscaled image's alpha to the stock silhouette.

The upscaler adds a faint alpha haze around every sprite (cursor_circle: 27% of texels at alpha 1-16
against 10% in stock). Sprites that stack, like the 24 cursor trail samples, turn that haze into a
visible halo. This clamps 4x alpha to the 3x3 maximum of the stock alpha, so no texel gets more
coverage than its stock neighbourhood had.

  python tools/alpha_mask.py <stock @2x.png> <upscaled 4x.png> [out.png]     (in place without out)
  python tools/alpha_mask.py --tree <stock res dir> <res dir with @4x files>  (whole tree, in place)
"""
import sys, pathlib
import numpy as np
from PIL import Image

def mask_alpha(stock_rgba: np.ndarray, up_rgba: np.ndarray) -> tuple[np.ndarray, int]:
    """Clamp upscaled alpha to the 3x3 maximum of the stock alpha (upsampled by the size ratio):
    the model may sharpen or soften an edge, but never add coverage the stock did not have."""
    a = stock_rgba[..., 3].astype(np.uint8)
    p = np.pad(a, 1, mode='edge')
    d = a.copy()
    for dy in (0, 1, 2):
        for dx in (0, 1, 2):
            np.maximum(d, p[dy:dy + a.shape[0], dx:dx + a.shape[1]], out=d)
    sy = up_rgba.shape[0] // a.shape[0]; sx = up_rgba.shape[1] // a.shape[1]
    m = np.repeat(np.repeat(d, sy, axis=0), sx, axis=1)
    m = np.pad(m, ((0, up_rgba.shape[0] - m.shape[0]), (0, up_rgba.shape[1] - m.shape[1])), constant_values=255)
    out = up_rgba.copy(); over = out[..., 3] > m
    out[..., 3] = np.minimum(out[..., 3], m)
    return out, int(over.sum())

def process(stock_path: pathlib.Path, up_path: pathlib.Path, out_path: pathlib.Path) -> int:
    s = np.asarray(Image.open(stock_path).convert('RGBA')); u = np.asarray(Image.open(up_path).convert('RGBA'))
    if s.shape[0] * 2 != u.shape[0] or s.shape[1] * 2 != u.shape[1]: return -1
    if not (s[..., 3] == 0).any(): return 0            # fully opaque: nothing to mask
    out, n = mask_alpha(s, u)
    if n: Image.fromarray(out).save(out_path)
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
