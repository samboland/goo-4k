"""Copy completed batch outputs into a res tree as name@4x.png (additive; stock @2x files untouched).

Input names are the flat encoded form: path segments joined by '__', without the @2x suffix.
Sidecar .png.txt files next to a stock @2x image are duplicated for the @4x name.
"""
import argparse, json, shutil, pathlib
p=argparse.ArgumentParser(); p.add_argument('batch'); p.add_argument('res'); p.add_argument('--stock',default=r'C:\Program Files (x86)\Steam\steamapps\common\World of Goo\game\res')
a=p.parse_args()
batch=pathlib.Path(a.batch); res=pathlib.Path(a.res); stock=pathlib.Path(a.stock)
rep=json.load(open(batch/'report.json'))
n=0; side=0
for e in rep['results']:
    name=e['name'][:-4]                       # strip .png
    rel=pathlib.Path(*name.split('__'))
    dst=res/rel.parent/(rel.name+'@4x.png')
    src=batch/e['name']
    if dst.exists() and dst.stat().st_size==src.stat().st_size: continue
    dst.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(src,dst); n+=1
    sc=stock/rel.parent/(rel.name+'@2x.png.txt')
    if sc.exists(): shutil.copy2(sc,res/rel.parent/(rel.name+'@4x.png.txt')); side+=1
print(f'installed {n} new @4x files ({len(rep["results"])} completed of {rep.get("total")}), {side} sidecars; status {rep.get("status")}')
