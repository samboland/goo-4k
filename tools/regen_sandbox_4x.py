"""Regenerate every @4x file in a res tree from the batch output with the pack rules (tiny images stay
stock, flat-colour images get their exact colour, alpha masked to the stock silhouette, cursor sprites
stay stock). Used to keep the test copy in step with build_pack.py.

  python tools/regen_sandbox_4x.py <batch out dir> <stock res dir> <target res dir>
"""
import sys, json, pathlib, shutil
import numpy as np
from PIL import Image
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent)); import alpha_mask as am
out, stock, res = (pathlib.Path(a) for a in sys.argv[1:4])
rep = json.loads((out / 'report.json').read_text()); n = skipped = 0
for e in rep['results']:
    name = e['name'][:-4]; rel = pathlib.Path(*name.split('__'))
    dst = res / rel.parent / (rel.name + '@4x.png'); src2x = stock / rel.parent / (rel.name + '@2x.png')
    if rel.as_posix() in ('images/cursor_circle', 'images/cursor_text') or not src2x.exists():
        if dst.exists(): dst.unlink()
        skipped += 1; continue
    a = np.asarray(Image.open(src2x).convert('RGBA'))
    if max(a.shape[:2]) <= 32:
        if dst.exists(): dst.unlink()
        skipped += 1; continue
    dst.parent.mkdir(parents=True, exist_ok=True)
    if a[..., :3].reshape(-1, 3).std(axis=0).max() < 0.5:
        bb = np.asarray(Image.open(out / e['name']).convert('RGBA')).copy(); bb[..., :3] = a[0, 0, :3]; Image.fromarray(bb).save(dst)
    else: shutil.copy2(out / e['name'], dst)
    am.process(src2x, dst, dst); n += 1
    sc = src2x.with_name(src2x.name + '.txt')
    if sc.exists(): shutil.copy2(sc, dst.with_name(dst.name + '.txt'))
print(f'{n} regenerated, {skipped} left stock')
