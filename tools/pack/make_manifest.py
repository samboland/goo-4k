"""Diff a stock binary against its patched version into a JSON manifest the installer can apply.

Manifest: {"name", "stock_sha256", "stock_size", "patched_sha256", "patched_size",
           "patches": [{"off", "old", "new"}...]  (hex, inside the stock size),
           "append": hex}                         (bytes beyond the stock size)
Every patch carries the expected old bytes, so the installer refuses a different build.
"""
import argparse, hashlib, json, pathlib

def diff(stock: bytes, patched: bytes):
    n = min(len(stock), len(patched))
    patches = []
    i = 0
    while i < n:
        if stock[i] == patched[i]:
            i += 1; continue
        j = i
        # extend the run; merge gaps of up to 8 equal bytes to keep the list short
        while j < n:
            if stock[j] != patched[j]:
                j += 1; continue
            k = j
            while k < n and stock[k] == patched[k] and k - j < 8: k += 1
            if k < n and stock[k] != patched[k]: j = k; continue
            break
        patches.append({"off": i, "old": stock[i:j].hex(), "new": patched[i:j].hex()})
        i = j
    assert len(patched) >= len(stock), "patched file shorter than stock"
    return patches, patched[len(stock):]

def main():
    p = argparse.ArgumentParser(); p.add_argument('stock'); p.add_argument('patched'); p.add_argument('out'); p.add_argument('--name', required=True)
    a = p.parse_args()
    stock = pathlib.Path(a.stock).read_bytes(); patched = pathlib.Path(a.patched).read_bytes()
    patches, tail = diff(stock, patched)
    m = {"name": a.name, "stock_sha256": hashlib.sha256(stock).hexdigest(), "stock_size": len(stock),
         "patched_sha256": hashlib.sha256(patched).hexdigest(), "patched_size": len(patched),
         "patches": patches, "append": tail.hex()}
    pathlib.Path(a.out).write_text(json.dumps(m, indent=1))
    print(f'{a.name}: {len(patches)} patch runs, {sum(len(x["new"])//2 for x in patches)} bytes changed, {len(tail)} bytes appended')

if __name__ == '__main__': main()
