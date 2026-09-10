"""Patch the stock SDL2.dll (2.0.9) shipped with World of Goo.

--no-minimize : SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS defaults to 0 (fullscreen window stays up on alt-tab).
--short       : fullscreen window is one row shorter than the display, so the compositor never
                promotes it to a fullscreen surface (composed presentation, no black handoff).
"""
import argparse, struct
p=argparse.ArgumentParser(); p.add_argument('src'); p.add_argument('dst'); p.add_argument('--no-minimize',action='store_true'); p.add_argument('--short',action='store_true')
a=p.parse_args()
d=bytearray(open(a.src,'rb').read())
pe=struct.unpack_from('<I',d,0x3c)[0]; nsec=struct.unpack_from('<H',d,pe+6)[0]; opt=struct.unpack_from('<H',d,pe+20)[0]; base=struct.unpack_from('<Q',d,pe+24+24)[0]
secs=[struct.unpack_from('<IIII',d,pe+24+opt+i*40+8) for i in range(nsec)]
def off(va):
    for vs,v,rs,ro in secs:
        if base+v<=va<base+v+max(vs,rs): return ro+(va-base-v)
    raise ValueError(hex(va))
if a.no_minimize:
    o=off(0x6c7f58a0); assert d[o:o+12]==bytes.fromhex('ba01000000488d0d2c980600'), d[o:o+12].hex(); d[o+1]=0
if a.short:
    # WIN_SetWindowFullscreen calls WIN_GetDisplayBounds(_this, display, &rect) at 0x6c827f41;
    # route it through a cave that decrements rect.h afterwards.
    site=0x6c827f41; orig=0x6c823520; cave=0x6c839358
    o=off(site); assert d[o]==0xe8 and struct.unpack_from('<i',d,o+1)[0]+site+5==orig
    code =b'\x48\x83\xec\x38'                                # sub rsp,0x38
    code+=b'\x4c\x89\x44\x24\x30'                            # mov [rsp+0x30],r8
    code+=b'\xe8'+struct.pack('<i',orig-(cave+len(code)+5))  # call WIN_GetDisplayBounds
    code+=b'\x4c\x8b\x44\x24\x30'                            # mov r8,[rsp+0x30]
    code+=b'\x41\xff\x48\x0c'                                # dec dword [r8+0xc]
    code+=b'\x48\x83\xc4\x38'                                # add rsp,0x38
    code+=b'\xc3'                                            # ret
    co=off(cave); assert set(d[co:co+len(code)])<={0,0xcc}
    d[co:co+len(code)]=code
    struct.pack_into('<i',d,o+1,cave-(site+5))
open(a.dst,'wb').write(d); print(a.dst,'no-minimize' if a.no_minimize else '','short' if a.short else '')
