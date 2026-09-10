# Render interpolation for World of Goo (Steam Win64 build 20824155).
# Simulation stays stock at 50 Hz. Around each draw, body/camera/cursor positions and
# the game clock are blended by the fraction of the tick elapsed, then restored.
# Lives in a new RWX section; BASE is its VA.
.intel_syntax noprefix
.set SCENE_TICK, 0x14009af30    # Scene::tick(scene, float time, float dt, bool)
.set WOG_TICK,   0x14008f3f0    # Wog::tick (Wog::vftable+0x30)
.set REND_DRAW,  0x1400933c0    # WogRenderer::draw(renderer, graphics) (vftable+8)
.set WOG_GET,    0x14008c9c0    # Wog* ()
.set ENV_GET,    0x1400972a0    # Boy::Environment* ()
.set MODEL_CAM,  0x140057870    # Camera* (Model)   current level scene camera
.set DEV_POS,    0x14009c800    # pos* (device): x +8, y +0xc
.set OP_NEW,     0x140271874    # operator new(size)
.set IAT_QPC,    0x1402ae238    # kernel32 QueryPerformanceCounter
.set IAT_QPF,    0x1402ae240    # kernel32 QueryPerformanceFrequency
.set ANIM_EVAL,  0x140029e10    # ImageAnimation evaluate(anim, float t, float t0, graphics); prologue relocated
.set ANIM_BACK,  0x140029e1b
.set BASE, 0x140398000
.set ENTRY_SHIFT, 17            # 4096 bodies * 32 bytes per world slot
.text
.globl _start
_start:
g_buf:       .quad 0
g_qpc_tick:  .quad 0
g_qpc_freq:  .quad 0
g_nworlds:   .long 0
g_indraw:    .long 0
g_alpha:     .float 0
g_fifty:     .float 50.0
g_one:       .float 1.0
             .long 0
g_worlds:    .fill 8,8,0
g_cam:       .quad 0
g_cam_prev:  .float 0,0
g_cam_save:  .float 0,0
g_cur_ptr:   .fill 4,8,0
g_cur_save:  .fill 8,4,0
g_tick:      .long 0
g_anim_n:    .long 0
g_anim_max:  .float 1.0        # ignore rate jumps larger than this per tick (loop wraps)
             .long 0
.p2align 4
g_anim:      .space 8192         # 256 x {anim ptr, last t, prev t, tick_last, tick_prev, pad}
.p2align 4

# ---------------------------------------------------------------- Scene::tick hook
.globl tramp
tramp:                              # rcx=scene xmm1=time xmm2=dt r9=flag
    push  rcx
    push  r9
    sub   rsp, 0x38
    movss dword ptr [rsp+0x20], xmm1
    movss dword ptr [rsp+0x24], xmm2
    mov   rcx, [rcx+0xe0]
    test  rcx, rcx
    jz    1f
    call  snapshot_world
1:  movss xmm1, dword ptr [rsp+0x20]
    movss xmm2, dword ptr [rsp+0x24]
    add   rsp, 0x38
    pop   r9
    pop   rcx
    jmp   _start+(SCENE_TICK-BASE)

# rcx = world. Record it for this tick (once) and copy body positions to prev.
snapshot_world:
    push  rbx
    push  rsi
    push  rdi
    push  r12
    sub   rsp, 0x28
    mov   rbx, rcx
    mov   ecx, dword ptr [rip+g_nworlds]
    xor   edx, edx
    lea   rax, [rip+g_worlds]
2:  cmp   edx, ecx
    jae   3f
    cmp   rbx, [rax+rdx*8]
    je    snap_done
    inc   edx
    jmp   2b
3:  cmp   ecx, 8
    jae   snap_done
    mov   [rax+rcx*8], rbx
    mov   r12d, ecx                     # slot
    inc   dword ptr [rip+g_nworlds]
    mov   rsi, [rip+g_buf]
    test  rsi, rsi
    jnz   4f
    mov   ecx, 0x100000
    call  _start+(OP_NEW-BASE)
    mov   [rip+g_buf], rax
    mov   rsi, rax
    test  rax, rax
    jz    snap_done
4:  mov   eax, r12d
    shl   rax, ENTRY_SHIFT
    add   rsi, rax                      # entries for this slot
    mov   edi, [rbx+0x8010]
    test  edi, edi
    js    snap_done
    cmp   edi, 4096
    jbe   5f
    mov   edi, 4096
5:  xor   r12d, r12d
snap_loop:
    cmp   r12d, edi
    jae   snap_done
    mov   rax, [rbx+0x10+r12*8]
    mov   [rsi], rax
    test  rax, rax
    jz    snap_next
    mov   ecx, [rax+0x28]
    mov   [rsi+8], ecx
    mov   ecx, [rax+0x2c]
    mov   [rsi+0xc], ecx
    mov   ecx, [rax+0x30]
    mov   [rsi+0x10], ecx
snap_next:
    add   rsi, 0x20
    inc   r12d
    jmp   snap_loop
snap_done:
    add   rsp, 0x28
    pop   r12
    pop   rdi
    pop   rsi
    pop   rbx
    ret

# ---------------------------------------------------------------- Wog::tick hook
.globl tick_hook
tick_hook:                          # rcx = Wog
    push  rbx
    sub   rsp, 0x20
    mov   rbx, rcx
    mov   dword ptr [rip+g_nworlds], 0
    inc   dword ptr [rip+g_tick]
    lea   rcx, [rip+g_qpc_tick]
    call  qword ptr [rip+_start+(IAT_QPC-BASE)]
    mov   qword ptr [rip+g_cam], 0
    mov   rcx, [rbx+0x10]
    test  rcx, rcx
    jz    1f
    call  _start+(MODEL_CAM-BASE)
    test  rax, rax
    jz    1f
    mov   [rip+g_cam], rax
    mov   ecx, [rax+0x18]
    mov   dword ptr [rip+g_cam_prev], ecx
    mov   ecx, [rax+0x1c]
    mov   dword ptr [rip+g_cam_prev+4], ecx
1:  mov   rcx, rbx
    add   rsp, 0x20
    pop   rbx
    jmp   _start+(WOG_TICK-BASE)

# ---------------------------------------------------------------- Wog::time replacement
.globl time_hook
time_hook:                          # rcx = Wog -> xmm0 seconds
    push  rbx
    sub   rsp, 0x20
    mov   rbx, rcx
    call  _start+(ENV_GET-BASE)
    mov   rcx, rax
    mov   rax, [rax]
    call  qword ptr [rax+0x58]          # ups
    cvtsi2ss xmm1, eax
    movss xmm0, dword ptr [rbx+0x54]
    cmp   dword ptr [rip+g_indraw], 0
    je    1f
    addss xmm0, dword ptr [rip+g_alpha]
1:  divss xmm0, xmm1
    mulss xmm0, dword ptr [rbx+0x50]
    addss xmm0, dword ptr [rbx+0x24]
    add   rsp, 0x20
    pop   rbx
    ret

# ---------------------------------------------------------------- WogRenderer::draw hook
.globl draw_hook
draw_hook:                          # rcx=renderer rdx=graphics
    push  rbx
    push  rsi
    push  rdi
    push  r12
    push  r13
    push  r14
    push  r15
    sub   rsp, 0x30
    mov   r14, rcx
    mov   r15, rdx
    # ---- alpha = clamp((now - tick) * 50 / freq, 0, 1)
    lea   rcx, [rsp+0x20]
    call  qword ptr [rip+_start+(IAT_QPC-BASE)]
    mov   rax, [rip+g_qpc_freq]
    test  rax, rax
    jnz   1f
    lea   rcx, [rip+g_qpc_freq]
    call  qword ptr [rip+_start+(IAT_QPF-BASE)]
1:  mov   rax, [rsp+0x20]
    sub   rax, [rip+g_qpc_tick]
    cvtsi2ss xmm0, rax
    mulss xmm0, dword ptr [rip+g_fifty]
    cvtsi2ss xmm1, qword ptr [rip+g_qpc_freq]
    divss xmm0, xmm1
    xorps xmm1, xmm1
    maxss xmm0, xmm1
    minss xmm0, dword ptr [rip+g_one]
    movss dword ptr [rip+g_alpha], xmm0
    mov   dword ptr [rip+g_indraw], 1
    # ---- bodies: save cur, write lerp
    xor   r12d, r12d
wloop:
    cmp   r12d, dword ptr [rip+g_nworlds]
    jae   wdone
    lea   rax, [rip+g_worlds]
    mov   rbx, [rax+r12*8]
    mov   rsi, [rip+g_buf]
    test  rsi, rsi
    jz    wdone
    mov   rax, r12
    shl   rax, ENTRY_SHIFT
    add   rsi, rax
    mov   edi, [rbx+0x8010]
    test  edi, edi
    js    wnext
    cmp   edi, 4096
    jbe   2f
    mov   edi, 4096
2:  xor   r13d, r13d
bloop:
    cmp   r13d, edi
    jae   wnext
    mov   rax, [rbx+0x10+r13*8]
    test  rax, rax
    jz    bskip
    cmp   rax, [rsi]
    jne   bskip
    mov   ecx, [rax+0x28]
    mov   [rsi+0x14], ecx
    mov   ecx, [rax+0x2c]
    mov   [rsi+0x18], ecx
    mov   ecx, [rax+0x30]
    mov   [rsi+0x1c], ecx
    movss xmm1, dword ptr [rip+g_alpha]
    movss xmm0, dword ptr [rax+0x28]
    subss xmm0, dword ptr [rsi+8]
    mulss xmm0, xmm1
    addss xmm0, dword ptr [rsi+8]
    movss dword ptr [rax+0x28], xmm0
    movss xmm0, dword ptr [rax+0x2c]
    subss xmm0, dword ptr [rsi+0xc]
    mulss xmm0, xmm1
    addss xmm0, dword ptr [rsi+0xc]
    movss dword ptr [rax+0x2c], xmm0
    movss xmm0, dword ptr [rax+0x30]
    subss xmm0, dword ptr [rsi+0x10]
    mulss xmm0, xmm1
    addss xmm0, dword ptr [rsi+0x10]
    movss dword ptr [rax+0x30], xmm0
    mov   byte ptr [rax+0x18], 1
    jmp   bnext
bskip:
    mov   qword ptr [rsi], 0
bnext:
    add   rsi, 0x20
    inc   r13d
    jmp   bloop
wnext:
    inc   r12d
    jmp   wloop
wdone:
    # ---- camera
    mov   rax, [rip+g_cam]
    test  rax, rax
    jz    cdone
    call  _start+(WOG_GET-BASE)
    mov   rcx, [rax+0x10]
    test  rcx, rcx
    jz    cinval
    call  _start+(MODEL_CAM-BASE)
    cmp   rax, [rip+g_cam]
    jne   cinval
    mov   ecx, [rax+0x18]
    mov   dword ptr [rip+g_cam_save], ecx
    mov   ecx, [rax+0x1c]
    mov   dword ptr [rip+g_cam_save+4], ecx
    movss xmm1, dword ptr [rip+g_alpha]
    movss xmm0, dword ptr [rax+0x18]
    subss xmm0, dword ptr [rip+g_cam_prev]
    mulss xmm0, xmm1
    addss xmm0, dword ptr [rip+g_cam_prev]
    movss dword ptr [rax+0x18], xmm0
    movss xmm0, dword ptr [rax+0x1c]
    subss xmm0, dword ptr [rip+g_cam_prev+4]
    mulss xmm0, xmm1
    addss xmm0, dword ptr [rip+g_cam_prev+4]
    movss dword ptr [rax+0x1c], xmm0
    mov   byte ptr [rax+8], 1
    jmp   cdone
cinval:
    mov   qword ptr [rip+g_cam], 0
cdone:
    # ---- cursors: head sample <- live device position
    call  _start+(WOG_GET-BASE)
    mov   rdi, [rax+0x10]               # Model
    xor   r12d, r12d
curs:
    lea   rax, [rip+g_cur_ptr]
    mov   qword ptr [rax+r12*8], 0
    test  rdi, rdi
    jz    curs_next
    mov   rsi, [rdi+0x2e0+r12*8]
    test  rsi, rsi
    jz    curs_next
    call  _start+(ENV_GET-BASE)
    mov   rcx, rax
    mov   edx, r12d
    mov   rax, [rax]
    call  qword ptr [rax+0x88]          # device i
    test  rax, rax
    jz    curs_next
    mov   rbx, rax
    mov   rcx, rax
    mov   rdx, [rax]
    call  qword ptr [rdx+0x10]          # active?
    test  al, al
    jz    curs_next
    mov   rcx, rbx
    call  _start+(DEV_POS-BASE)
    lea   rcx, [rip+g_cur_ptr]
    mov   [rcx+r12*8], rsi
    lea   rcx, [rip+g_cur_save]
    mov   edx, [rsi+0x28]
    mov   [rcx+r12*8], edx
    mov   edx, [rsi+0x2c]
    mov   [rcx+r12*8+4], edx
    mov   edx, [rax+8]
    mov   [rsi+0x28], edx
    mov   edx, [rax+0xc]
    mov   [rsi+0x2c], edx
curs_next:
    inc   r12d
    cmp   r12d, 4
    jb    curs
    # ---- original draw
    mov   rcx, r14
    mov   rdx, r15
    call  _start+(REND_DRAW-BASE)
    mov   dword ptr [rip+g_indraw], 0
    # ---- restore cursors
    xor   r12d, r12d
rcurs:
    lea   rax, [rip+g_cur_ptr]
    mov   rsi, [rax+r12*8]
    test  rsi, rsi
    jz    rcurs_next
    lea   rcx, [rip+g_cur_save]
    mov   edx, [rcx+r12*8]
    mov   [rsi+0x28], edx
    mov   edx, [rcx+r12*8+4]
    mov   [rsi+0x2c], edx
rcurs_next:
    inc   r12d
    cmp   r12d, 4
    jb    rcurs
    # ---- restore camera
    mov   rax, [rip+g_cam]
    test  rax, rax
    jz    rcdone
    mov   ecx, dword ptr [rip+g_cam_save]
    mov   [rax+0x18], ecx
    mov   ecx, dword ptr [rip+g_cam_save+4]
    mov   [rax+0x1c], ecx
    mov   byte ptr [rax+8], 1
rcdone:
    # ---- restore bodies
    xor   r12d, r12d
rwloop:
    cmp   r12d, dword ptr [rip+g_nworlds]
    jae   rwdone
    lea   rax, [rip+g_worlds]
    mov   rbx, [rax+r12*8]
    mov   rsi, [rip+g_buf]
    test  rsi, rsi
    jz    rwdone
    mov   rax, r12
    shl   rax, ENTRY_SHIFT
    add   rsi, rax
    mov   edi, [rbx+0x8010]
    test  edi, edi
    js    rwnext
    cmp   edi, 4096
    jbe   3f
    mov   edi, 4096
3:  xor   r13d, r13d
rbloop:
    cmp   r13d, edi
    jae   rwnext
    mov   rax, [rsi]
    test  rax, rax
    jz    rbnext
    cmp   rax, [rbx+0x10+r13*8]
    jne   rbnext
    mov   ecx, [rsi+0x14]
    mov   [rax+0x28], ecx
    mov   ecx, [rsi+0x18]
    mov   [rax+0x2c], ecx
    mov   ecx, [rsi+0x1c]
    mov   [rax+0x30], ecx
    mov   byte ptr [rax+0x18], 1
rbnext:
    add   rsi, 0x20
    inc   r13d
    jmp   rbloop
rwnext:
    inc   r12d
    jmp   rwloop
rwdone:
    add   rsp, 0x30
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rdi
    pop   rsi
    pop   rbx
    ret

# ---------------------------------------------------------------- keyframe evaluator detour
# Entered from the jmp at ANIM_EVAL. rcx=anim, xmm1=t (per-tick progress). While drawing,
# extrapolate t by the frame fraction times the rate observed between the last two ticks.
.globl anim_hook
anim_hook:
    cmp   dword ptr [rip+g_indraw], 0
    je    anim_out
    lea   r10, [rip+g_anim]
    mov   r11d, dword ptr [rip+g_anim_n]
    xor   eax, eax
1:  cmp   eax, r11d
    jae   anim_new
    cmp   rcx, [r10]
    je    anim_found
    add   r10, 32
    inc   eax
    jmp   1b
anim_new:
    cmp   r11d, 256
    jae   anim_out
    inc   dword ptr [rip+g_anim_n]
    mov   [r10], rcx
    movss dword ptr [r10+8], xmm1
    movss dword ptr [r10+12], xmm1
    mov   eax, dword ptr [rip+g_tick]
    mov   [r10+16], eax
    mov   [r10+20], eax
    jmp   anim_out
anim_found:
    ucomiss xmm1, dword ptr [r10+8]
    jp    2f
    je    3f
2:  mov   eax, [r10+8]                  # value changed: shift history
    mov   [r10+12], eax
    mov   eax, [r10+16]
    mov   [r10+20], eax
    movss dword ptr [r10+8], xmm1
    mov   eax, dword ptr [rip+g_tick]
    mov   [r10+16], eax
3:  mov   eax, dword ptr [rip+g_tick]
    cmp   eax, [r10+16]
    jne   anim_out                      # did not change in the latest tick: hold
    mov   eax, [r10+16]
    sub   eax, [r10+20]
    jle   anim_out
    cvtsi2ss xmm5, eax
    movss xmm4, dword ptr [r10+8]
    subss xmm4, dword ptr [r10+12]
    divss xmm4, xmm5                    # rate per tick
    movaps xmm5, xmm4
    andps xmm5, xmmword ptr [rip+g_absmask]
    ucomiss xmm5, dword ptr [rip+g_anim_max]
    ja    anim_out                      # loop wrap or reset: hold
    movss xmm5, dword ptr [rip+g_one]   # interpolate: t = last - (1 - alpha) * rate
    subss xmm5, dword ptr [rip+g_alpha]
    mulss xmm4, xmm5
    subss xmm1, xmm4
anim_out:
    push  rbx                           # relocated prologue of ANIM_EVAL
    push  rbp
    push  rdi
    sub   rsp, 0x90
    jmp   _start+(ANIM_BACK-BASE)
.p2align 4
g_absmask:   .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
