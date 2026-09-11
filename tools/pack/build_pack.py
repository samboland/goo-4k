"""Build the distributable patcher folder (and optionally the texture pack) from the stock game files.

  python tools/pack/build_pack.py [--stock "<World of Goo dir>"] [--textures work/batch-all/out ...] [--version v]
Output: dist/goo4k-<version>/ (installer) and dist/goo4k-textures-<version>.zip (if --textures given)
"""
import argparse, subprocess, pathlib, shutil, struct, sys, json, datetime, zipfile
root = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--stock', default=r'C:\Program Files (x86)\Steam\steamapps\common\World of Goo')
p.add_argument('--textures', nargs='*', default=[], help='batch output dirs (with report.json) to pack as @4x files')
p.add_argument('--version', default=None)
a = p.parse_args()
stock = pathlib.Path(a.stock)
rev = subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], cwd=root).decode().strip()
version = a.version or (datetime.date.today().strftime('%Y%m%d') + '-' + rev)
out = root / 'dist' / f'goo4k-{version}'
work = root / 'work' / 'pack'
for d in (out, work): shutil.rmtree(d, ignore_errors=True); d.mkdir(parents=True)
py = sys.executable

# 1. exe: stock -> asset scale patch -> interpolation/loader build
stock_exe = stock / 'Win64' / 'WorldOfGoo.exe'
scaled = work / 'WorldOfGoo-scaleonly.exe'
d = bytearray(stock_exe.read_bytes())
off = 0x1400d7c6d - 0x140001000 + 0x400 + 4          # movss xmm0,[rip+disp] -> 0.25f constant
assert d[off:off+4] == bytes.fromhex('8b781d00'), d[off:off+4].hex()
d[off:off+4] = bytes.fromhex('338f1d00')
scaled.write_bytes(d)
patched_exe = work / 'WorldOfGoo.exe'
subprocess.check_call([py, str(root / 'tools/interp/build.py'), str(scaled), str(patched_exe)])

# 2. SDL2_real.dll: stock SDL2.dll with the no-minimize default
stock_sdl = stock / 'Win64' / 'SDL2.dll'
real = work / 'SDL2_real.dll'
subprocess.check_call([py, str(root / 'tools/sdl2_patch.py'), str(stock_sdl), str(real), '--no-minimize'])

# 3. shim
shim = root / 'tools/present/SDL2.dll'
assert shim.exists(), 'build the shim first (sh tools/present/build.sh)'

# 4. manifests + files
(out / 'patches').mkdir(); (out / 'files').mkdir()
# 4b. fonts: resources.xml with font atlases rasterised at 4x (tools/font_scale.py), plus stock/patched hashes
import hashlib, importlib.util
spec = importlib.util.spec_from_file_location('font_scale', root / 'tools/font_scale.py'); fs = importlib.util.module_from_spec(spec); spec.loader.exec_module(fs)
stock_res = stock / 'game/properties/resources.xml'
res_text, nfonts = fs.rescale(stock_res.read_text(encoding='utf-8'), 4.0)
(out / 'files/resources.xml').write_text(res_text, encoding='utf-8', newline='')
sha = lambda b: hashlib.sha256(b).hexdigest()
(out / 'patches/resources.xml.json').write_text(json.dumps({'name': 'game/properties/resources.xml', 'stock_sha256': sha(stock_res.read_bytes()), 'patched_sha256': sha((out / 'files/resources.xml').read_bytes()), 'fonts': nfonts, 'factor': 4}, indent=1))
subprocess.check_call([py, str(root / 'tools/pack/make_manifest.py'), str(stock_exe), str(patched_exe), str(out / 'patches/WorldOfGoo.exe.json'), '--name', 'WorldOfGoo.exe'])
subprocess.check_call([py, str(root / 'tools/pack/make_manifest.py'), str(stock_sdl), str(real), str(out / 'patches/SDL2_real.dll.json'), '--name', 'SDL2_real.dll'])
shutil.copy2(shim, out / 'files/SDL2.dll')
for f in ('install.ps1', 'install.cmd', 'uninstall.cmd', 'README.txt'): shutil.copy2(root / 'tools/pack' / f, out / f)
(out / 'VERSION').write_text(version + '\n')
zi = root / 'dist' / f'goo4k-{version}.zip'
with zipfile.ZipFile(zi, 'w', zipfile.ZIP_DEFLATED) as zf:
    for f in sorted(out.rglob('*')):
        if f.is_file(): zf.write(f, (out.name + '/' + f.relative_to(out).as_posix()))
print('installer:', out, 'and', zi)

# 5. textures
if a.textures:
    tex = work / 'textures' / 'res'; n = 0
    for b in a.textures:
        b = pathlib.Path(b); rep = json.loads((b / 'report.json').read_text())
        for e in rep['results']:
            name = e['name'][:-4]; rel = pathlib.Path(*name.split('__'))
            dst = tex / rel.parent / (rel.name + '@4x.png'); dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(b / e['name'], dst); n += 1
            sc = stock / 'game/res' / rel.parent / (rel.name + '@2x.png.txt')
            if sc.exists(): shutil.copy2(sc, tex / rel.parent / (rel.name + '@4x.png.txt'))
    z = root / 'dist' / f'goo4k-textures-{version}.zip'
    with zipfile.ZipFile(z, 'w', zipfile.ZIP_STORED) as zf:
        for f in sorted(tex.rglob('*')):
            if f.is_file(): zf.write(f, 'textures/' + f.relative_to(work / 'textures').as_posix())
    print(f'texture pack: {z} ({n} files, {z.stat().st_size/1e6:.0f} MB)')
