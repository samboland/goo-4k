"""Write a side-by-side HTML review page for a test set: original vs each result folder."""
import sys,html
from pathlib import Path
from PIL import Image
root=Path(sys.argv[1]); results=sys.argv[2:]
inputs=sorted((root/'inputs').glob('*.png'))
rows=[]
for src in inputs:
    with Image.open(src) as im: w,h=im.size
    cells=[f'<figure><img src="inputs/{src.name}" style="width:{w*2}px;image-rendering:pixelated"><figcaption>original {w}x{h} (nearest 2x)</figcaption></figure>']
    for r in results:
        out=root/r/src.name
        if out.exists():
            with Image.open(out) as im: ow,oh=im.size
            cells.append(f'<figure><img src="{r}/{src.name}" style="width:{ow}px"><figcaption>{r} {ow}x{oh}</figcaption></figure>')
        else: cells.append(f'<figure><figcaption>{r}: missing</figcaption></figure>')
    rows.append(f'<section><h2>{html.escape(src.name)}</h2><div class="row">{"".join(cells)}</div></section>')
page=f'''<!doctype html><meta charset=utf-8><title>goo-4k test set</title>
<style>body{{background:#333;color:#ddd;font:14px system-ui;margin:16px}} .row{{display:flex;gap:16px;overflow-x:auto;align-items:flex-start}}
figure{{margin:0;flex:none;background:repeating-conic-gradient(#555 0 25%,#444 0 50%) 0 0/24px 24px}} figcaption{{background:#222;padding:4px}} img{{display:block;max-width:none}}
h2{{font-size:14px;margin:24px 0 6px}} .zoom{{position:sticky;top:0;background:#222;padding:8px}}</style>
<div class=zoom>Zoom <input type=range min=0.25 max=4 step=0.25 value=1 oninput="document.querySelectorAll('img').forEach(i=>{{i.style.transform='scale('+this.value+')';i.style.transformOrigin='0 0'}})"> (scroll rows horizontally)</div>
{"".join(rows)}'''
(root/'compare.html').write_text(page,encoding='utf-8'); print(root/'compare.html')
