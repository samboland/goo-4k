"""Build WorldOfGoo.exe with render interpolation (tools/interp/cave.s).

Adds an RWX section '.goo' at RVA 0x398000 (right after .reloc), assembles cave.s there,
and installs four hooks: the five Scene::tick call sites -> tramp (snapshot),
Wog::vftable+0x30 -> tick_hook, WogRenderer::vftable+8 -> draw_hook, and a jmp at the
start of Wog::time -> time_hook. Tick rate stays stock (50).
"""
import argparse, struct, subprocess, pathlib, tempfile
p=argparse.ArgumentParser(); p.add_argument('src'); p.add_argument('dst'); a=p.parse_args()
here=pathlib.Path(__file__).parent
d=bytearray(open(a.src,'rb').read())
pe=struct.unpack_from('<I',d,0x3c)[0]; opt=pe+24
nsec=struct.unpack_from('<H',d,pe+6)[0]; optsize=struct.unpack_from('<H',d,pe+20)[0]
sec=lambda i: pe+24+optsize+i*40
IMG=0x140000000; SEC_RVA=0x398000; SEC_VA=IMG+SEC_RVA; SEC_VSIZE=0x1000
names=[bytes(d[sec(i):sec(i)+8]).rstrip(b'\0') for i in range(nsec)]
assert names[-1]==b'.reloc', names
assert struct.unpack_from('<I',d,opt+56)[0]==SEC_RVA, 'unexpected SizeOfImage'
assert sec(nsec)+40<=struct.unpack_from('<I',d,opt+60)[0], 'no room for a section header'
# --- assemble ---
with tempfile.TemporaryDirectory() as t:
    t=pathlib.Path(t)
    subprocess.check_call(['as','--64','-o',str(t/'c.o'),str(here/'cave.s')])
    subprocess.check_call(['ld',f'-Ttext={SEC_VA:#x}','-e','_start','-o',str(t/'c.elf'),str(t/'c.o')],stderr=subprocess.DEVNULL)
    subprocess.check_call(['objcopy','-O','binary','-j','.text',str(t/'c.elf'),str(t/'c.bin')])
    blob=(t/'c.bin').read_bytes()
    syms={l.split()[2]:int(l.split()[0],16) for l in subprocess.check_output(['nm',str(t/'c.elf')]).decode().splitlines() if len(l.split())==3}
assert len(blob)<=SEC_VSIZE
# --- append section ---
raw=(len(blob)+0x1ff)&~0x1ff
ptr=(len(d)+0x1ff)&~0x1ff
d+=bytes(ptr-len(d)); d+=blob+bytes(raw-len(blob))
hdr=struct.pack('<8sIIIIIIHHI',b'.goo',SEC_VSIZE,SEC_RVA,raw,ptr,0,0,0,0,0xE0000060)  # code|init|exec|read|write
d[sec(nsec):sec(nsec)+40]=hdr
struct.pack_into('<H',d,pe+6,nsec+1)
struct.pack_into('<I',d,opt+56,SEC_RVA+SEC_VSIZE)
struct.pack_into('<I',d,opt+64,0)           # checksum
def va2off(va):
    for i in range(nsec):
        vs,va0,rs_,ro_=struct.unpack_from('<IIII',d,sec(i)+8)
        if IMG+va0<=va<IMG+va0+max(vs,rs_): return ro_+(va-(IMG+va0))
    raise ValueError(hex(va))
# --- hooks ---
SCENE_TICK=0x14009af30
for s in (0x14004ea6e,0x14004ea9f,0x140061597,0x1400615cf,0x140061d9a):
    o=va2off(s); assert d[o]==0xe8 and struct.unpack_from('<i',d,o+1)[0]+s+5==SCENE_TICK, hex(s)
    struct.pack_into('<i',d,o+1,syms['tramp']-(s+5))
for slot,orig,new in ((0x1402b5af0+0x30,0x14008f3f0,'tick_hook'),(0x1402b5f38+0x8,0x1400933c0,'draw_hook')):
    o=va2off(slot); assert struct.unpack_from('<Q',d,o)[0]==orig, hex(slot)
    struct.pack_into('<Q',d,o,syms[new])
o=va2off(0x14008a920); assert d[o:o+6]==bytes.fromhex('40534883ec20'), d[o:o+6].hex()
d[o:o+6]=b'\xe9'+struct.pack('<i',syms['time_hook']-(0x14008a920+5))+b'\x90'
# --- sanity: stock tick rate, stock time scale ---
assert d[va2off(0x1400ab237)]==0x32
assert d[va2off(0x140089020):va2off(0x140089020)+8]==bytes.fromhex('48c747500000803f')
open(a.dst,'wb').write(d)
print(f'{a.dst}: section .goo at {SEC_VA:#x} ({len(blob)} bytes), tramp {syms["tramp"]:#x} tick {syms["tick_hook"]:#x} draw {syms["draw_hook"]:#x} time {syms["time_hook"]:#x}')
