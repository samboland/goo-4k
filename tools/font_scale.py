"""Rescale the font entries in properties/resources.xml so glyph atlases are rasterised larger.

Each <font> has pointSize (rasterised size) and scale (draw scale). Multiplying pointSize by F and
dividing scale by F keeps text the same size on screen with F times the pixels. Pixel-unit
attributes (outlineSize, glowSize, spacing, lineSpacingOffset, ascentPadding, lineHeightPadding*)
scale with F. Idempotent: a <!-- goo4k:F --> comment precedes each rescaled entry.

  python tools/font_scale.py <resources.xml> [--factor 2]
"""
import argparse, re, pathlib
PIXEL_ATTRS = ('pointSize', 'outlineSize', 'glowSize', 'spacing', 'lineSpacingOffset', 'ascentPadding')

def fmt(v: float) -> str:
    return str(int(v)) if float(v).is_integer() else ('%.4f' % v).rstrip('0').rstrip('.')

def rescale(text: str, factor: float):
    n = 0
    def fix(m):
        nonlocal n
        if m.group(1): return m.group(0)          # already rescaled
        body = m.group(2)
        def attr(mm):
            k, v = mm.group(1), mm.group(2)
            base = k.split('_')[0]
            if k == 'scale': return f'{k}="{fmt(float(v) / factor)}"'
            if base in PIXEL_ATTRS or base == 'lineHeightPadding': return f'{k}="{fmt(float(v) * factor)}"'
            return mm.group(0)
        body = re.sub(r'(\w[\w\-]*)="([^"]*)"', attr, body)
        n += 1
        return f'<!-- goo4k:{fmt(factor)} --><font {body}/>'
    return re.sub(r'(<!-- goo4k:[0-9.]+ -->)?<font\s+(.*?)/>', fix, text, flags=re.S), n

if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('xml'); p.add_argument('--factor', type=float, default=2.0)
    a = p.parse_args()
    path = pathlib.Path(a.xml); text = path.read_text(encoding='utf-8', newline='')
    out, n = rescale(text, a.factor)
    path.write_text(out, encoding='utf-8', newline='')
    print(f'{path}: {n} font entries rescaled by {a.factor}')
