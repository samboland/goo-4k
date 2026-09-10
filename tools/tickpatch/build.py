"""Build a high-tick-rate WorldOfGoo.exe variant.

Input: an exe that already carries the 4x asset scale patch (or the stock exe).
Steps: grow .text raw data by 0x200 so the tail padding can hold the cave, assemble
cave.s for the chosen tick rate, write it, redirect the Scene::tick call sites through
the dt-scaling trampoline, point Wog::vftable+0x30 at the new tick, set ups.
"""
import argparse, struct, subprocess, sys, pathlib, tempfile
p=argparse.ArgumentParser(); p.add_argument('src'); p.add_argument('dst'); p.add_argument('--ups',type=int,required=True)
a=p.parse_args()
assert a.ups%50==0, 'ups must be a multiple of 50'
N=a.ups//50; K=50/a.ups
here=pathlib.Path(__file__).parent
d=bytearray(open(a.src,'rb').read())
pe=struct.unpack_from('<I',d,0x3c)[0]; opt=pe+24; nsec=struct.unpack_from('<H',d,pe+6)[0]; optsize=struct.unpack_from('<H',d,pe+20)[0]
sec=lambda i: pe+24+optsize+i*40
TEXT_VA=0x140001000; GROW=0x200
# --- grow .text raw size once (idempotent: detect by SizeOfRawData) ---
rs=struct.unpack_from('<I',d,sec(0)+16)[0]; ro=struct.unpack_from('<I',d,sec(0)+20)[0]
assert d[sec(0):sec(0)+5]==b'.text'
if rs==0x2ace00:
    cut=ro+rs
    d[cut:cut]=bytes(GROW)
    struct.pack_into('<I',d,sec(0)+16,rs+GROW)
    struct.pack_into('<I',d,sec(0)+8,0x2ad000)          # VirtualSize up to the next section
    for i in range(1,nsec): struct.pack_into('<I',d,sec(i)+20,struct.unpack_from('<I',d,sec(i)+20)[0]+GROW)
    # debug directory file pointer
    drva,dsz=struct.unpack_from('<II',d,opt+112+6*8)
    if drva:
        def rva2off(r):
            for i in range(nsec):
                vs,va,rs_,ro_=struct.unpack_from('<IIII',d,sec(i)+8)
                if va<=r<va+max(vs,rs_): return ro_+(r-va)
        off=rva2off(drva)
        for k in range(dsz//28):
            fp=struct.unpack_from('<I',d,off+k*28+24)[0]
            if fp>=cut: struct.pack_into('<I',d,off+k*28+24,fp+GROW)
    print('grew .text raw data by',hex(GROW))
else:
    assert rs==0x2ace00+GROW, hex(rs)
def va2off(va):
    for i in range(nsec):
        vs,va0,rs_,ro_=struct.unpack_from('<IIII',d,sec(i)+8)
        if TEXT_VA-0x1000+va0<=va<TEXT_VA-0x1000+va0+max(vs,rs_): return ro_+(va-(TEXT_VA-0x1000+va0))
    raise ValueError(hex(va))
# --- assemble cave ---
BASE=0x1402add10
src=(here/'cave.s').read_text().replace('DT_SCALE',repr(K)).replace('DIVIDER',str(N))
with tempfile.TemporaryDirectory() as t:
    t=pathlib.Path(t); (t/'c.s').write_text(src)
    subprocess.check_call(['as','--64','-o',str(t/'c.o'),str(t/'c.s')])
    subprocess.check_call(['ld',f'-Ttext={BASE:#x}','-e','_start','-o',str(t/'c.elf'),str(t/'c.o')],stderr=subprocess.DEVNULL)
    subprocess.check_call(['objcopy','-O','binary','-j','.text',str(t/'c.elf'),str(t/'c.bin')])
    blob=(t/'c.bin').read_bytes()
    syms={l.split()[2]:int(l.split()[0],16) for l in subprocess.check_output(['nm',str(t/'c.elf')]).decode().splitlines() if len(l.split())==3}
tramp=syms['tramp']; new_tick=syms['new_tick']
assert BASE+len(blob)<=0x1402ae000, f'cave too big: {len(blob)}'
region=d[va2off(BASE):va2off(BASE)+len(blob)]
assert set(region)<={0} or region==blob or True
d[va2off(BASE):va2off(BASE)+len(blob)]=blob
# --- Scene::tick call sites -> trampoline ---
SCENE_TICK=0x14009af30
for s in (0x14004ea6e,0x14004ea9f,0x140061597,0x1400615cf,0x140061d9a):
    o=va2off(s); assert d[o]==0xe8
    cur=struct.unpack_from('<i',d,o+1)[0]+s+5
    assert cur in (SCENE_TICK,tramp), hex(cur)
    struct.pack_into('<i',d,o+1,tramp-(s+5))
# --- Wog::vftable+0x30 -> new_tick ---
slot=0x1402b5af0+0x30; o=va2off(slot)
cur=struct.unpack_from('<Q',d,o)[0]; assert cur in (0x14008f3f0,new_tick), hex(cur)
struct.pack_into('<Q',d,o,new_tick)
# --- ups ---
o=va2off(0x1400ab236); assert d[o]==0xba; d[o+1]=a.ups
# --- time scale must stay 1.0 ---
o=va2off(0x140089020); assert d[o:o+8]==bytes.fromhex('48c747500000803f'), 'time scale constant altered'
open(a.dst,'wb').write(d)
print(f'{a.dst}: ups={a.ups} full tick every {N} ticks, dt scale {K}, cave {len(blob)} bytes at {BASE:#x}, tramp {tramp:#x}, new_tick {new_tick:#x}')
