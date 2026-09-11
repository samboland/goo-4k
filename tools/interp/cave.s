# Render interpolation for World of Goo (Steam Win64 build 20824155).
# Simulation stays stock at 50 Hz. Around each draw, body/camera/cursor positions and
# the game clock are blended by the fraction of the tick elapsed, then restored.
# Lives in a new RWX section; BASE is its VA.
.intel_syntax noprefix
.set SCENE_TICK, 0x14009af30    # Scene::tick(scene, float time, float dt, bool)
.set WOG_TICK,   0x14008f3f0    # Wog::tick (Wog::vftable+0x30)
.set REND_DRAW,  0x1400933c0    # WogRenderer::draw(renderer, graphics) (vftable+8)
.set REND_FX,    0x140094480    # WogRenderer effects pass (vftable+0x10): particles read the clock, keep it tick-exact
.set WOG_GET,    0x14008c9c0    # Wog* ()
.set ENV_GET,    0x1400972a0    # Boy::Environment* ()
.set MODEL_CAM,  0x140057870    # Camera* (Model)   current level scene camera
.set DEV_POS,    0x14009c800    # pos* (device): x +8, y +0xc
.set OP_NEW,     0x140271874    # operator new(size)
.set FX_FACTORY, 0x140017690    # EffectsFactory* ()
.set FX_CREATE,  0x1400175d0    # Effect* (factory, string* outId, string* name, float depth)
.set VEC2_VT,    0x1402aea48    # BoyLib::Vector2::vftable
.set MODEL_LEVEL, 0x140057a30   # Level* (Model)
.set SCENE_ADD,  0x140098870    # Scene::addObject(scene, object)
.set IAT_QPC,    0x1402ae238    # kernel32 QueryPerformanceCounter
.set IAT_QPF,    0x1402ae240    # kernel32 QueryPerformanceFrequency
.set ANIM_EVAL,  0x140029e10    # ImageAnimation evaluate(anim, float t, float t0, graphics); prologue relocated
.set ANIM_BACK,  0x140029e1b
.set PDRAW,      0x14006d8c0    # Particle draw (vtable +0x58) for Particle and SuckEffectParticle
.set PDRAW_SH,   0x14007ed40    # ShatterParticle draw (vtable +0x58)
.set PFX_DRAW,   0x140003762    # return address of the evaluator call in the particle effect draw
.set IMG_UPLOAD, 0x1400c6520    # SDL2Image upload (lazy glTexImage2D) -> GL id
.set GLYPH_BACK, 0x1400b10a5
.set GL_GENMIP,  0x140367b20    # GL function table (GetProcAddress at startup): glGenerateMipmap
.set GL_BINDTEX, 0x140368550    # glBindTexture
.set GL_TEXPARI, 0x140368458    # glTexParameteri
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
g_wcount:    .fill 8,4,0
g_rot_max:   .float 3.0
g_cam:       .quad 0
g_cam_prev:  .float 0,0
g_cam_save:  .float 0,0
g_cur_ptr:   .fill 4,8,0
g_cur_save:  .fill 8,4,0
g_sfx2x:     .asciz "@2x.png"
g_stamp:     .asciz "GOO4K:BUILD_STAMP"
g_dbgmark:   .asciz "GOO4KDEBUG"
             .byte 0
g_debug:     .long 0            # shim writes 1 on F5: spawn an unlock burst at the camera
g_burstname: .asciz "unlockburst"
             .space 4
g_flagmark:  .asciz "GOO4KFLAGS"
             .byte 0
g_flags:     .long 0xffffffff   # 1 bodies, 2 clock, 4 keyframe anims, 8 camera, 16 cursor, 32 particles, 64 font mipmaps (shim writes from ini)
g_tick:      .long 0
g_noclock:   .long 0
g_anim_n:    .long 0
g_anim_max:  .float 0.15       # ignore time jumps larger than this per tick (restarts, loop wraps)
g_body_max:  .float 200.0      # skip body lerp when it moved more than this in one tick (slot reuse)
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
5:  lea   rax, [rip+g_wcount]
    mov   edx, [rax+r12*4]              # old count for this slot
    mov   [rax+r12*4], edi              # new count
    cmp   edx, edi
    jbe   6f
    sub   edx, edi                      # entries [new, old): invalidate
    mov   rax, rdi
    shl   rax, 5
    add   rax, rsi
7:  mov   qword ptr [rax], 0
    add   rax, 0x20
    dec   edx
    jnz   7b
6:  xor   r12d, r12d
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
1:  cmp   dword ptr [rip+g_debug], 1
    jne   5f
    call  debug_burst
5:  mov   rcx, rbx
    add   rsp, 0x20
    pop   rbx
    jmp   _start+(WOG_TICK-BASE)

# rbx = Wog. Spawn the "unlockburst" particle effect at the current camera position.
debug_burst:
    push  rsi
    push  rdi
    sub   rsp, 0x88                     # locals: name string +0x20, out string +0x40, vec +0x60
    mov   dword ptr [rip+g_debug], 2    # status: no camera
    mov   rax, [rip+g_cam]
    test  rax, rax
    jz    9f
    mov   esi, [rax+0x18]               # camera x, y
    mov   edi, [rax+0x1c]
    lea   rax, [rip+g_burstname]
    mov   rcx, [rax]
    mov   [rsp+0x20], rcx
    mov   rcx, [rax+8]
    mov   [rsp+0x28], rcx
    mov   qword ptr [rsp+0x30], 11
    mov   qword ptr [rsp+0x38], 15
    mov   byte ptr [rsp+0x40], 0
    mov   qword ptr [rsp+0x50], 0
    mov   qword ptr [rsp+0x58], 15
    call  _start+(FX_FACTORY-BASE)
    mov   rcx, rax
    lea   rdx, [rsp+0x40]
    lea   r8, [rsp+0x20]
    movss xmm3, dword ptr [rip+g_one]
    mov   dword ptr [rip+g_debug], 3    # status: create failed
    call  _start+(FX_CREATE-BASE)
    test  rax, rax
    jz    9f
    mov   dword ptr [rip+g_debug], 4    # status: spawned
    mov   rcx, VEC2_VT
    mov   [rsp+0x60], rcx
    mov   [rsp+0x68], esi
    mov   [rsp+0x6c], edi
    mov   dword ptr [rax+0x100], 0x1e
    mov   [rsp+0x70], rax               # effect
    mov   rcx, rax
    lea   rdx, [rsp+0x60]
    mov   rax, [rax]
    call  qword ptr [rax+0x20]          # setPosition(vec)
    mov   rcx, [rbx+0x10]               # Model
    test  rcx, rcx
    jz    9f
    call  _start+(MODEL_LEVEL-BASE)
    test  rax, rax
    jz    9f
    mov   rcx, [rax+0x178]              # level main scene
    test  rcx, rcx
    jz    9f
    mov   rdx, [rsp+0x70]
    call  _start+(SCENE_ADD-BASE)       # what EffectLauncher::tick does
    mov   dword ptr [rip+g_debug], 5    # status: added to scene
9:  add   rsp, 0x88
    pop   rdi
    pop   rsi
    ret

# ---------------------------------------------------------------- Wog::time replacement
.globl time_hook
time_hook:                          # rcx = Wog -> xmm0 seconds
    push  rbx
    sub   rsp, 0x20
    mov   rbx, rcx
    xor   r9d, r9d                      # r9d = 1 when the caller is an animation site that may see the advanced clock
    mov   rax, [rsp+0x28]               # return address of the original call
    mov   r8, 0x14001f45b               # scene object draw: animation apply
    cmp   rax, r8
    je    2f
    mov   r8, 0x14001f499
    cmp   rax, r8
    je    2f
    mov   r8, 0x14002b1b0               # image drawable keyframe time
    cmp   rax, r8
    jne   3f
2:  mov   r9d, 1
3:
    call  _start+(ENV_GET-BASE)
    mov   rcx, rax
    mov   rax, [rax]
    call  qword ptr [rax+0x58]          # ups
    cvtsi2ss xmm1, eax
    movss xmm0, dword ptr [rbx+0x54]
    test  r9d, r9d
    jz    1f
    cmp   dword ptr [rip+g_indraw], 0
    je    1f
    test  dword ptr [rip+g_flags], 2
    jz    1f
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
    test  dword ptr [rip+g_flags], 1
    jz    wdone
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
    lea   rax, [rip+g_wcount]
    cmp   edi, [rax+r12*4]
    jbe   2f
    mov   edi, [rax+r12*4]              # bodies added after the snapshot are not interpolated
2:  cmp   edi, 4096
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
    movss xmm0, dword ptr [rax+0x28]    # reject teleports (slot reused by a new body)
    subss xmm0, dword ptr [rsi+8]
    andps xmm0, xmmword ptr [rip+g_absmask]
    ucomiss xmm0, dword ptr [rip+g_body_max]
    ja    bnext
    movss xmm0, dword ptr [rax+0x2c]
    subss xmm0, dword ptr [rsi+0xc]
    andps xmm0, xmmword ptr [rip+g_absmask]
    ucomiss xmm0, dword ptr [rip+g_body_max]
    ja    bnext
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
    movaps xmm2, xmm0
    andps xmm2, xmmword ptr [rip+g_absmask]
    ucomiss xmm2, dword ptr [rip+g_rot_max]
    ja    8f                            # angle wrapped: keep the current rotation
    mulss xmm0, xmm1
    addss xmm0, dword ptr [rsi+0x10]
    movss dword ptr [rax+0x30], xmm0
8:  mov   byte ptr [rax+0x18], 1
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
    test  dword ptr [rip+g_flags], 8
    jz    cdone
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
    test  dword ptr [rip+g_flags], 16
    jz    curs_next
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
    test  dword ptr [rip+g_flags], 8
    jz    rcdone
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
    test  dword ptr [rip+g_flags], 1
    jz    rwdone
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
    lea   rax, [rip+g_wcount]
    cmp   edi, [rax+r12*4]
    jbe   3f
    mov   edi, [rax+r12*4]
3:  cmp   edi, 4096
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
    test  dword ptr [rip+g_flags], 4
    jz    anim_out
    lea   rax, [rip+_start+(PFX_DRAW-BASE)]   # particle effect draw: per-particle anims churn, no interpolation
    cmp   [rsp], rax
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
    mov   [r10+24], eax
    mov   dword ptr [r10+28], 0
    jmp   anim_out
anim_found:
    mov   eax, dword ptr [rip+g_tick]
    mov   r11d, eax
    sub   r11d, [r10+24]                # ticks since last drawn
    mov   [r10+24], eax
    cmp   r11d, 2
    jbe   4f
    movss dword ptr [r10+8], xmm1       # stale entry (object went away): restart history
    movss dword ptr [r10+12], xmm1
    mov   [r10+16], eax
    mov   [r10+20], eax
    mov   dword ptr [r10+28], 0
    jmp   anim_out
4:  cmp   dword ptr [r10+28], 0
    jne   anim_out                      # clock-driven: changes every frame, already smooth
    ucomiss xmm1, dword ptr [r10+8]
    jp    2f
    je    3f
2:  mov   eax, dword ptr [rip+g_tick]
    cmp   eax, [r10+16]
    jne   9f
    mov   dword ptr [r10+28], 1         # changed twice within one tick
    jmp   anim_out
9:  mov   eax, [r10+8]                  # value changed: shift history
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
    xorps xmm4, xmm4
    maxss xmm1, xmm4                    # never below zero
anim_out:
    push  rbx                           # relocated prologue of ANIM_EVAL
    push  rbp
    push  rdi
    sub   rsp, 0x90
    jmp   _start+(ANIM_BACK-BASE)
.p2align 4
g_absmask:   .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff

# ---------------------------------------------------------------- effects pass wrapper
.globl fx_hook
fx_hook:                            # rcx=renderer rdx=graphics r8=camera
    push  rbx
    sub   rsp, 0x20
    mov   dword ptr [rip+g_noclock], 1
    call  _start+(REND_FX-BASE)
    mov   dword ptr [rip+g_noclock], 0
    add   rsp, 0x20
    pop   rbx
    ret

# ---------------------------------------------------------------- particle draw wrappers
# rcx=particle rdx=graphics r8=camera xmm3=scale. Particles move by velocity (+0x58/+0x5c, px per
# tick) once per tick; while drawing, push the draw position (+0xb8/+0xbc) forward by velocity
# times the frame fraction, call the stock draw, restore. Feature bit 32.
.globl pdraw_hook
pdraw_hook:
    lea   rax, [rip+_start+(PDRAW-BASE)]
    jmp   pdraw_common
.globl pdraw_sh_hook
pdraw_sh_hook:
    lea   rax, [rip+_start+(PDRAW_SH-BASE)]
pdraw_common:
    push  rbx
    sub   rsp, 0x40                     # +0x20 flag, +0x24 saved x, +0x28 saved y, +0x30 original draw
    mov   rbx, rcx
    mov   [rsp+0x30], rax               # original draw
    mov   dword ptr [rsp+0x20], 0       # 1 = adjusted
    cmp   dword ptr [rip+g_indraw], 0
    je    1f
    test  dword ptr [rip+g_flags], 32
    jz    1f
    mov   eax, [rbx+0xb8]
    mov   [rsp+0x24], eax               # saved draw x
    mov   eax, [rbx+0xbc]
    mov   [rsp+0x28], eax               # saved draw y
    movss xmm0, dword ptr [rip+g_alpha]
    movss xmm1, dword ptr [rbx+0x58]
    mulss xmm1, xmm0
    addss xmm1, dword ptr [rbx+0xb8]
    movss dword ptr [rbx+0xb8], xmm1
    movss xmm1, dword ptr [rbx+0x5c]
    mulss xmm1, xmm0
    addss xmm1, dword ptr [rbx+0xbc]
    movss dword ptr [rbx+0xbc], xmm1
    mov   dword ptr [rsp+0x20], 1
1:  call  qword ptr [rsp+0x30]
    cmp   dword ptr [rsp+0x20], 0
    je    2f
    mov   eax, [rsp+0x24]
    mov   [rbx+0xb8], eax
    mov   eax, [rsp+0x28]
    mov   [rbx+0xbc], eax
2:  add   rsp, 0x40
    pop   rbx
    ret

# --- glyph_hook: detour at 0x1400b109d, right after the glyph rasteriser's createImage call
# (Font glyph -> SDL2Image, FUN_1400b0960). Relocated: mov [rbp-0x50],rax ; mov rdx,[rbp+0x20].
# Uploads the glyph texture now (the engine would do it lazily at first draw), then lifts the
# GL_TEXTURE_MAX_LEVEL=0 clamp, generates mipmaps and sets LINEAR_MIPMAP_LINEAR minification.
# Glyphs are rasterised at 4x pointSize and drawn at 0.125 scale, so plain bilinear skipped
# texels and rotated text looked jagged. Flag 64.
.globl glyph_hook
glyph_hook:
    mov   [rbp-0x50], rax               # relocated: keep the image pointer
    test  rax, rax
    jz    glyph_out
    test  dword ptr [rip+g_flags], 64
    jz    glyph_out
    cmp   qword ptr [rip+_start+(GL_GENMIP-BASE)], 0   # GetProcAddress result, may be null
    je    glyph_out
    sub   rsp, 0x30                     # rsp%16==0 here (post-call), 0x20 shadow + scratch
    mov   rcx, rax
    call  _start+(IMG_UPLOAD-BASE)      # -> eax = GL texture id
    mov   [rsp+0x20], eax
    mov   ecx, 0xde1
    mov   edx, eax
    call  qword ptr [rip+_start+(GL_BINDTEX-BASE)]
    mov   ecx, 0xde1
    mov   edx, 0x813d                   # GL_TEXTURE_MAX_LEVEL
    mov   r8d, 1000
    call  qword ptr [rip+_start+(GL_TEXPARI-BASE)]
    mov   ecx, 0xde1
    call  qword ptr [rip+_start+(GL_GENMIP-BASE)]
    mov   ecx, 0xde1
    mov   edx, 0x2801                   # GL_TEXTURE_MIN_FILTER
    mov   r8d, 0x2703                   # GL_LINEAR_MIPMAP_LINEAR
    call  qword ptr [rip+_start+(GL_TEXPARI-BASE)]
    add   rsp, 0x30
glyph_out:
    mov   rdx, [rbp+0x20]               # relocated
    jmp   _start+(GLYPH_BACK-BASE)
