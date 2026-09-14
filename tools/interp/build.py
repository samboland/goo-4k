"""Build WorldOfGoo.exe with render interpolation (tools/interp/cave.s).

Adds an RWX section '.goo' at RVA 0x398000 (right after .reloc), assembles cave.s there,
and installs the hooks: the five Scene::tick call sites -> tramp (snapshot),
Wog::vftable+0x30 -> tick_hook, WogRenderer::vftable+8 -> draw_hook, a jmp at the start
of Wog::time -> time_hook, and a jmp at the start of the keyframe animation evaluator
-> anim_hook. Tick rate stays stock (50).
"""
import argparse, struct, subprocess, pathlib, tempfile
p=argparse.ArgumentParser(); p.add_argument('src'); p.add_argument('dst'); a=p.parse_args()
here=pathlib.Path(__file__).parent
d=bytearray(open(a.src,'rb').read())
pe=struct.unpack_from('<I',d,0x3c)[0]; opt=pe+24
nsec=struct.unpack_from('<H',d,pe+6)[0]; optsize=struct.unpack_from('<H',d,pe+20)[0]
sec=lambda i: pe+24+optsize+i*40
IMG=0x140000000; SEC_RVA=0x398000; SEC_VA=IMG+SEC_RVA; SEC_VSIZE=0x10000
names=[bytes(d[sec(i):sec(i)+8]).rstrip(b'\0') for i in range(nsec)]
assert names[-1]==b'.reloc', names
assert struct.unpack_from('<I',d,opt+56)[0]==SEC_RVA, 'unexpected SizeOfImage'
assert sec(nsec)+40<=struct.unpack_from('<I',d,opt+60)[0], 'no room for a section header'
# --- assemble ---
with tempfile.TemporaryDirectory() as t:
    t=pathlib.Path(t)
    import datetime
    try: rev=subprocess.check_output(['git','rev-parse','--short','HEAD'],cwd=here).decode().strip()
    except Exception: rev='nogit'
    stamp=datetime.datetime.now().strftime('%m-%d %H:%M')+' '+rev
    (t/'cave.s').write_text((here/'cave.s').read_text().replace('BUILD_STAMP',stamp))
    subprocess.check_call(['as','--64','-o',str(t/'c.o'),str(t/'cave.s')])
    subprocess.check_call(['gcc','-c','-O2','-ffreestanding','-fno-builtin','-fno-tree-loop-distribute-patterns','-fno-stack-protector','-fno-asynchronous-unwind-tables','-mno-stack-arg-probe','-fno-jump-tables','-o',str(t/'soften.o'),str(here/'soften.c')])
    und=[l for l in subprocess.check_output(['nm',str(t/'soften.o')]).decode().splitlines() if ' U ' in l]
    assert not und, 'soften.c must be freestanding: '+' '.join(und)
    subprocess.check_call(['ld',f'-Ttext={SEC_VA:#x}','-e','_start','-o',str(t/'c.elf'),str(t/'c.o'),str(t/'soften.o')],stderr=subprocess.DEVNULL)
    subprocess.check_call(['objcopy','-O','binary','-j','.text',str(t/'c.elf'),str(t/'c.bin')])
    blob=(t/'c.bin').read_bytes()
    syms={l.split()[2]:int(l.split()[0],16) for l in subprocess.check_output(['nm',str(t/'c.elf')]).decode().splitlines() if len(l.split())==3}
assert len(blob)<=SEC_VSIZE, len(blob)
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
def jmp_patch(va,expect_hex,target):
    o=va2off(va); n=len(expect_hex)//2
    assert d[o:o+n]==bytes.fromhex(expect_hex), d[o:o+n].hex()
    d[o:o+n]=b'\xe9'+struct.pack('<i',target-(va+5))+b'\x90'*(n-5)
# --- hooks ---
SCENE_TICK=0x14009af30
for s in (0x14004ea6e,0x14004ea9f,0x140061597,0x1400615cf,0x140061d9a):
    o=va2off(s); assert d[o]==0xe8 and struct.unpack_from('<i',d,o+1)[0]+s+5==SCENE_TICK, hex(s)
    struct.pack_into('<i',d,o+1,syms['tramp']-(s+5))
for slot,orig,new in ((0x1402b5af0+0x30,0x14008f3f0,'tick_hook'),(0x1402b5f38+0x8,0x1400933c0,'draw_hook'),(0x1402b5f38+0x10,0x140094480,'fx_hook'),
                    (0x1402b3d88+0x58,0x14006d8c0,'pdraw_hook'),(0x1402b5150+0x58,0x14006d8c0,'pdraw_hook'),(0x1402b48d0+0x58,0x14007ed40,'pdraw_sh_hook')):
    o=va2off(slot); assert struct.unpack_from('<Q',d,o)[0]==orig, hex(slot)
    struct.pack_into('<Q',d,o,syms[new])
jmp_patch(0x14008a920,'40534883ec20',syms['time_hook'])                 # Wog::time, fully replaced
jmp_patch(0x140029e10,'405355574881ec90000000',syms['anim_hook'])       # evaluator prologue, relocated in cave
jmp_patch(0x1400b109d,'488945b0488b5520',syms['glyph_hook'])          # after glyph createImage, relocated in cave
jmp_patch(0x1400c6520,'48895c240848896c2410',syms['upload_hook'])   # SDL2Image upload prologue, relocated in cave
jmp_patch(0x1400b0674,'894e5c8b566003d1895664',syms['margin_hook'])  # face setup: glyph bitmap margin, relocated in cave
jmp_patch(0x1400b0ade,'660f6e83900000000f5bc0',syms['bearing_hook']) # rasteriser: bitmap_left -> float, relocated in cave
jmp_patch(0x1400a1170,'48895c241048894c2408',syms['fontctor_hook'])  # Font::Font prologue, relocated in cave
jmp_patch(0x1400a13b0,'48895c24084889742410',syms['fontdtor_hook'])  # Font::~Font prologue, relocated in cave
# --- two-suffix loader: try "@4x.png" (scale 0.25), fall back to "@2x.png" (scale 0.5) ---
o=va2off(0x1402b8370); assert d[o:o+8]==b'@2x.png'+bytes(1), bytes(d[o:o+8]); d[o:o+8]=b'@4x.png'+bytes(1)
sfx2=syms['g_sfx2x']                                  # "@2x.png" in the .goo section
for site in (0x1400bb34b,0x1400bb79a,0x1400bb97d):     # lea r9/r8, [rip+".png"] -> "@2x.png"
    o=va2off(site); assert d[o:o+3] in (bytes.fromhex('4c8d0d'),bytes.fromhex('4c8d05')), d[o:o+3].hex()
    assert struct.unpack_from('<i',d,o+3)[0]+site+7==0x1402b837c
    struct.pack_into('<i',d,o+3,sfx2-(site+7))
for site in (0x1400bb342,0x1400bb791):                 # movq $4 -> $7 (suffix length)
    o=va2off(site); assert d[o:o+9]==bytes.fromhex('48c744242004000000'), d[o:o+9].hex()
    d[o+5]=7
for site in (0x1400bb355,0x1400bb7a4):                 # mov edx,4 -> 7
    o=va2off(site); assert d[o:o+5]==bytes.fromhex('ba04000000'); d[o+1]=7
o=va2off(0x1400d7c77)                                  # non-4x path scale 1.0 -> 0.5
assert d[o:o+8]==bytes.fromhex('f30f1005c16e1d00'), d[o:o+8].hex()
struct.pack_into('<i',d,o+4,0x1402af500-(0x1400d7c77+8))
# --- SDL2Image upload: do not clamp GL_TEXTURE_MAX_LEVEL to 0 (pname 0x813d -> 0x813c, a redundant BASE_LEVEL=0);
#     glyph textures get mipmaps after the upload, and raising the cap afterwards forced a reallocation per glyph
o=va2off(0x1400c65d3); assert d[o:o+5]==bytes.fromhex('ba3d810000'), d[o:o+5].hex(); d[o+1]=0x3c
# --- sanity: stock tick rate, stock time scale ---
assert d[va2off(0x1400ab237)]==0x32
assert d[va2off(0x140089020):va2off(0x140089020)+8]==bytes.fromhex('48c747500000803f')
open(a.dst,'wb').write(d)
print(f'stamp {stamp}'); print(f'{a.dst}: section .goo at {SEC_VA:#x} ({len(blob)} bytes)', ' '.join(f'{k} {syms[k]:#x}' for k in ('tramp','tick_hook','draw_hook','time_hook','anim_hook')))
