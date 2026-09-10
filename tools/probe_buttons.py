"""Sample ButtonGizmo positionable fields in the running game to see what animates and how often."""
import ctypes, ctypes.wintypes as w, struct, time, sys
k=ctypes.windll.kernel32; psapi=ctypes.windll.psapi
PROCESS_QUERY_INFORMATION=0x400; PROCESS_VM_READ=0x10
pid=int(sys.argv[1]); rva=int(sys.argv[2],16)   # vtable RVA
h=k.OpenProcess(PROCESS_QUERY_INFORMATION|PROCESS_VM_READ,False,pid); assert h
psapi.EnumProcessModulesEx.argtypes=[w.HANDLE,ctypes.POINTER(ctypes.c_void_p),w.DWORD,ctypes.POINTER(w.DWORD),w.DWORD]
psapi.GetModuleFileNameExW.argtypes=[w.HANDLE,ctypes.c_void_p,ctypes.c_wchar_p,w.DWORD]
mods=(ctypes.c_void_p*1024)(); need=w.DWORD()
psapi.EnumProcessModulesEx(h,mods,ctypes.sizeof(mods),ctypes.byref(need),0x03)
base=None
for i in range(need.value//8):
    name=ctypes.create_unicode_buffer(260); psapi.GetModuleFileNameExW(h,mods[i],name,260)
    if name.value.lower().endswith('.exe'): base=mods[i]; break
vt=base+rva; print('base',hex(base),'vtable',hex(vt))
class MBI(ctypes.Structure): _fields_=[('BaseAddress',ctypes.c_void_p),('AllocationBase',ctypes.c_void_p),('AllocationProtect',w.DWORD),('PartitionId',w.WORD),('RegionSize',ctypes.c_size_t),('State',w.DWORD),('Protect',w.DWORD),('Type',w.DWORD)]
k.VirtualQueryEx.restype=ctypes.c_size_t; k.VirtualQueryEx.argtypes=[w.HANDLE,ctypes.c_void_p,ctypes.POINTER(MBI),ctypes.c_size_t]
k.ReadProcessMemory.argtypes=[w.HANDLE,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.POINTER(ctypes.c_size_t)]
def read(addr,n):
    buf=ctypes.create_string_buffer(n); got=ctypes.c_size_t()
    return buf.raw[:got.value] if k.ReadProcessMemory(h,addr,buf,n,ctypes.byref(got)) else b''
hits=[]; addr=0; needle=struct.pack('<Q',vt); m=MBI()
while addr<0x7fffffffffff and k.VirtualQueryEx(h,addr,ctypes.byref(m),ctypes.sizeof(m)):
    if m.BaseAddress and m.State==0x1000 and m.Protect in (0x04,0x08) and m.Type==0x20000 and m.RegionSize<0x8000000:
        data=read(m.BaseAddress,m.RegionSize); i=data.find(needle)
        while i!=-1:
            if i%8==0: hits.append(m.BaseAddress+i)
            i=data.find(needle,i+8)
    addr=(m.BaseAddress or 0)+m.RegionSize
print('instances',len(hits))
for obj in hits[:6]:
    samples=[]; t0=time.perf_counter(); last=None
    while time.perf_counter()-t0<1.0:
        d=read(obj+0x8,0x40)
        if len(d)<0x40: break
        cur=struct.unpack_from('<B',d,0)[0], struct.unpack_from('<ff',d,0x10), struct.unpack_from('<f',d,0x18)[0], struct.unpack_from('<Q',d,0x20)[0]
        if cur!=last: samples.append((time.perf_counter()-t0,cur)); last=cur
    iv=[round((samples[i][0]-samples[i-1][0])*1000,1) for i in range(1,len(samples))]
    print(hex(obj),'changes/s',len(samples)-1,'first',samples[0][1] if samples else None,'intervals ms',iv[:12])
