# High-rate simulation for World of Goo (Steam Win64 build 20824155).
# Placed in the .text tail padding. Symbols are absolute VAs of the stock exe.
.intel_syntax noprefix
.set WOG_TICK,      0x14008f3f0   # Wog::tick (Wog::vftable+0x30)
.set SCENE_TICK,    0x14009af30   # Scene::tick(scene, float time, float dt, bool)
.set WOG_TIME,      0x14008a920   # float Wog::time()
.set LEVEL_SYNC,    0x1400508d0   # (level, bool before)
.set SCENE_WORLD,   0x1400301e0   # world* (scene)   (second world of the level scene)
.set WORLD_TICK,    0x140206400   # World::tick(world, float dt, bool)
.set ENV_GET,       0x1400972a0   # Boy::Environment* ()
.set DEV_POS,       0x14009c800   # pos* (device)  x at +8, y at +0xc
.set BASE, 0x1402add10
.set COUNTER, 0x14036d4c0         # zero-filled tail of .data (writable)
.text
.globl _start
_start:
K:          .float DT_SCALE          # 50 / ups
one:        .float 1.0
# --- trampoline: scale dt then Scene::tick (patched call sites land here) ---
.globl tramp
tramp:
    mulss xmm2, dword ptr [rip+K]
    jmp   _start+(SCENE_TICK-BASE)
# --- world step helper: rcx = scene, xmm1 = scaled dt ---
world_step:
    mov   rcx, [rcx+0xe0]
    test  rcx, rcx
    jz    1f
    mov   r8d, 1
    jmp   _start+(WORLD_TICK-BASE)
1:  ret
# --- replacement for Wog::tick ---
.globl new_tick
new_tick:
    mov   eax, dword ptr [rip+_start+(COUNTER-BASE)]
    inc   eax
    cmp   eax, DIVIDER
    jb    phys
    mov   dword ptr [rip+_start+(COUNTER-BASE)], 0
    jmp   _start+(WOG_TICK-BASE)              # full tick every DIVIDER ticks
phys:
    mov   dword ptr [rip+_start+(COUNTER-BASE)], eax
    push  rbx
    push  rsi
    push  rdi
    push  r12
    sub   rsp, 0x28
    mov   rbx, rcx                       # Wog
    movss xmm0, dword ptr [rbx+0x54]     # clock ticks += 1
    addss xmm0, dword ptr [rip+one]
    movss dword ptr [rbx+0x54], xmm0
    movss xmm0, dword ptr [rbx+0x50]     # dt = time scale * K
    mulss xmm0, dword ptr [rip+K]
    movss dword ptr [rsp+0x20], xmm0
    mov   rdi, [rbx+0x10]                # Model
    test  rdi, rdi
    jz    done
    # ---- cursors: refresh head sample from the input device, no trail shift ----
    xor   r12d, r12d
curs:
    mov   rsi, [rdi+0x2e0+r12*8]
    test  rsi, rsi
    jz    curs_next
    call  _start+(ENV_GET-BASE)
    mov   rcx, rax
    mov   edx, r12d
    mov   rax, [rax]
    call  qword ptr [rax+0x88]           # device i
    test  rax, rax
    jz    curs_next
    mov   rcx, rax
    mov   rdx, [rax]
    call  qword ptr [rdx+0x10]           # active?
    test  al, al
    jz    curs_next
    call  _start+(ENV_GET-BASE)
    mov   rcx, rax
    mov   edx, r12d
    mov   rax, [rax]
    call  qword ptr [rax+0x88]
    mov   rcx, rax
    call  _start+(DEV_POS-BASE)
    mov   edx, [rax+8]
    mov   [rsi+0x28], edx
    mov   edx, [rax+0xc]
    mov   [rsi+0x2c], edx
curs_next:
    inc   r12d
    cmp   r12d, 4
    jb    curs
    # ---- physics ----
    xorps xmm0, xmm0
    ucomiss xmm0, dword ptr [rsp+0x20]
    jp    1f
    je    overlay                        # paused: only the overlay scene
1:  mov   eax, [rdi+0x18]                # state -> level
    xor   esi, esi
    cmp   eax, 1
    jne   1f
    mov   rsi, [rdi+0xb0]
    jmp   2f
1:  cmp   eax, 3
    jne   1f
    mov   rsi, [rdi+0xc0]
    jmp   2f
1:  cmp   eax, 4
    je    3f
    cmp   eax, 5
    jne   2f
3:  mov   rsi, [rdi+0xb8]
2:  test  rsi, rsi
    jz    scenes
    cmp   byte ptr [rsi+0x390], 0
    jne   scenes
    mov   rcx, rsi                       # level pre-sync
    mov   edx, 1
    call  _start+(LEVEL_SYNC-BASE)
    mov   rcx, [rsi+0x178]
    movss xmm1, dword ptr [rsp+0x20]
    call  world_step
    mov   rcx, rsi                       # level post-sync
    xor   edx, edx
    call  _start+(LEVEL_SYNC-BASE)
    mov   rcx, [rsi+0x140]
    test  rcx, rcx
    jz    scenes
    movss xmm1, dword ptr [rsp+0x20]
    call  world_step
    mov   rcx, [rsi+0x140]
    call  _start+(SCENE_WORLD-BASE)
    test  rax, rax
    jz    scenes
    mov   rcx, rax
    movss xmm1, dword ptr [rsp+0x20]
    mov   r8d, 1
    call  _start+(WORLD_TICK-BASE)
scenes:
    mov   rcx, [rdi+0x90]
    test  rcx, rcx
    jz    5f
    movss xmm1, dword ptr [rsp+0x20]
    call  world_step
5:  mov   rcx, [rdi+0xa0]
    test  rcx, rcx
    jz    overlay
    movss xmm1, dword ptr [rsp+0x20]
    call  world_step
overlay:
    mov   rcx, [rdi+0x98]
    test  rcx, rcx
    jz    done
    movss xmm1, dword ptr [rip+K]        # stock passes 1.0 here
    call  world_step
done:
    add   rsp, 0x28
    pop   r12
    pop   rdi
    pop   rsi
    pop   rbx
    ret
