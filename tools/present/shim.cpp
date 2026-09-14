// Proxy SDL2.dll for World of Goo: presents the OpenGL frame through a DXGI flip-model
// swapchain (WGL_NV_DX_interop2) instead of the driver's GL window presentation.
// Every other export forwards to SDL2_real.dll (see SDL2.def).
//
// Build: see build.sh. Log: %LOCALAPPDATA%\2DBoy\WorldOfGoo\goopresent.log
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_5.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include <GL/wglext.h>
#include <d2d1.h>
#include <dwrite.h>
#include <cstdio>
#include <cstdarg>
#include <cstdlib>

typedef struct SDL_Window SDL_Window;

static FILE* g_log = nullptr;
static void logf(const char* fmt, ...) {
    if (!g_log) {
        char path[MAX_PATH]; DWORD n = GetEnvironmentVariableA("LOCALAPPDATA", path, MAX_PATH);
        if (n && n < MAX_PATH) { strcat_s(path, "\\2DBoy\\WorldOfGoo\\goopresent.log"); g_log = fopen(path, "w"); }
        if (!g_log) g_log = fopen("goopresent.log", "w");
    }
    if (!g_log) return;
    va_list ap; va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap); fputc('\n', g_log); fflush(g_log);
}

// ---- real SDL entry points we replace
typedef void (*PFN_SwapWindow)(SDL_Window*);
typedef int  (*PFN_SetSwapInterval)(int);
typedef int  (*PFN_GetSwapInterval)(void);
static PFN_SwapWindow      real_SwapWindow = nullptr;
static PFN_SetSwapInterval real_SetSwapInterval = nullptr;
static PFN_GetSwapInterval real_GetSwapInterval = nullptr;
typedef void (*PFN_GetDrawableSize)(SDL_Window*, int*, int*);
static PFN_GetDrawableSize real_GetDrawableSize = nullptr;
static SDL_Window* g_win = nullptr;
static HMODULE g_real = nullptr;

static void load_real() {
    if (g_real) return;
    g_real = LoadLibraryA("SDL2_real.dll");
    if (!g_real) { logf("SDL2_real.dll not found"); return; }
    real_SwapWindow = (PFN_SwapWindow)GetProcAddress(g_real, "SDL_GL_SwapWindow");
    real_SetSwapInterval = (PFN_SetSwapInterval)GetProcAddress(g_real, "SDL_GL_SetSwapInterval");
    real_GetSwapInterval = (PFN_GetSwapInterval)GetProcAddress(g_real, "SDL_GL_GetSwapInterval");
    real_GetDrawableSize = (PFN_GetDrawableSize)GetProcAddress(g_real, "SDL_GL_GetDrawableSize");
}

// ---- GL / WGL function pointers (resolved with the game's context current)
static PFNGLGENFRAMEBUFFERSPROC        p_glGenFramebuffers;
static PFNGLDELETEFRAMEBUFFERSPROC     p_glDeleteFramebuffers;
static PFNGLBINDFRAMEBUFFERPROC        p_glBindFramebuffer;
static PFNGLFRAMEBUFFERTEXTURE2DPROC   p_glFramebufferTexture2D;
static PFNGLBLITFRAMEBUFFERPROC        p_glBlitFramebuffer;
static PFNGLCHECKFRAMEBUFFERSTATUSPROC p_glCheckFramebufferStatus;
static PFNWGLDXOPENDEVICENVPROC        p_wglDXOpenDeviceNV;
static PFNWGLDXCLOSEDEVICENVPROC       p_wglDXCloseDeviceNV;
static PFNWGLDXREGISTEROBJECTNVPROC    p_wglDXRegisterObjectNV;
static PFNWGLDXUNREGISTEROBJECTNVPROC  p_wglDXUnregisterObjectNV;
static PFNWGLDXLOCKOBJECTSNVPROC       p_wglDXLockObjectsNV;
static PFNWGLDXUNLOCKOBJECTSNVPROC     p_wglDXUnlockObjectsNV;

template <class T> static bool gl_load(T& fn, const char* name) {
    fn = (T)wglGetProcAddress(name);
    if (!fn) logf("missing %s", name);
    return fn != nullptr;
}

// ---- presentation state
static bool   g_disabled = false;     // fall back to the real swap
static bool   g_inited = false;
static HWND   g_hwnd = nullptr;
static int    g_w = 0, g_h = 0;
static int    g_interval = -1;        // last SDL_GL_SetSwapInterval value
static bool   g_tearing = false;
static ID3D11Device*        g_dev = nullptr;
static ID3D11DeviceContext* g_ctx = nullptr;
static IDXGISwapChain1*     g_sc = nullptr;
static ID3D11Texture2D*     g_shared = nullptr;   // GL renders into this via interop
static HANDLE g_interop = nullptr, g_sharedH = nullptr;
static GLuint g_tex = 0, g_fbo = 0;
static unsigned g_frames = 0;
static bool g_overlay = true;
static double   g_cap_period = 0;      // seconds per frame when fps_cap is set
static LARGE_INTEGER g_qpf = {}, g_last_present = {};

static int g_interp_flags = -1;       // ini: interp=<mask>; -1 leaves the exe default (all on)
static bool g_debug_keys = false;     // ini: debug=1 enables F5
static int g_dump_frames = 0;         // ini: dump_frames=N saves the first N presented frames as BMP next to the log
static int g_font_pad = 8;            // ini: font_pad, extra transparent texels around glyph bitmaps (0 = stock)
static int g_font_soften = 1;         // ini: font_soften, outer-edge alpha ramp radius in texels (0 = off)
static int g_font_warm = 1;           // ini: font_warm, rasterise the tooltip fonts' ASCII set during the first frames
static void apply_flags();

// goopresent.ini next to the config: fps_cap=<n> (0 = off). Env GOO_FPS_CAP overrides.
static void read_settings() {
    double cap = 0;
    char path[MAX_PATH]; DWORD n = GetEnvironmentVariableA("LOCALAPPDATA", path, MAX_PATH);
    if (n && n < MAX_PATH) {
        strcat_s(path, "\\2DBoy\\WorldOfGoo\\goopresent.ini");
        if (FILE* f = fopen(path, "r")) { char line[256]; while (fgets(line, sizeof line, f)) { double v; int o; if (sscanf(line, " fps_cap = %lf", &v) == 1 || sscanf(line, " fps_cap=%lf", &v) == 1) cap = v; if (sscanf(line, " overlay = %d", &o) == 1 || sscanf(line, " overlay=%d", &o) == 1) g_overlay = o != 0; if (sscanf(line, " interp = %d", &o) == 1 || sscanf(line, " interp=%d", &o) == 1) g_interp_flags = o; if (sscanf(line, " debug = %d", &o) == 1 || sscanf(line, " debug=%d", &o) == 1) g_debug_keys = o != 0; if (sscanf(line, " dump_frames = %d", &o) == 1 || sscanf(line, " dump_frames=%d", &o) == 1) g_dump_frames = o; if (sscanf(line, " font_pad = %d", &o) == 1 || sscanf(line, " font_pad=%d", &o) == 1) g_font_pad = o; if (sscanf(line, " font_soften = %d", &o) == 1 || sscanf(line, " font_soften=%d", &o) == 1) g_font_soften = o; if (sscanf(line, " font_warm = %d", &o) == 1 || sscanf(line, " font_warm=%d", &o) == 1) g_font_warm = o; } fclose(f); }
    }
    if (const char* e = getenv("GOO_FPS_CAP")) cap = atof(e);
    g_cap_period = cap > 0 ? 1.0 / cap : 0;
    apply_flags();
    QueryPerformanceFrequency(&g_qpf);
    logf("fps_cap=%.1f", cap);
}

static void wait_for_cap() {
    if (g_cap_period <= 0) return;
    LARGE_INTEGER now; QueryPerformanceCounter(&now);
    if (g_last_present.QuadPart) {
        double target = g_last_present.QuadPart + g_cap_period * g_qpf.QuadPart;
        for (;;) {
            QueryPerformanceCounter(&now);
            double remaining = (target - now.QuadPart) / (double)g_qpf.QuadPart;
            if (remaining <= 0) break;
            if (remaining > 0.002) Sleep(1); else YieldProcessor();
        }
    }
    g_last_present = now;
}

// ---- build stamp overlay (Direct2D on the shared texture)
static ID2D1Factory* g_d2d = nullptr;
static IDWriteFactory* g_dw = nullptr;
static IDWriteTextFormat* g_fmt = nullptr;
static ID2D1RenderTarget* g_rt = nullptr;
static ID2D1SolidColorBrush* g_brush = nullptr;
static wchar_t g_text[256] = L"";

static BYTE* find_goo_marker(const char* marker) {
    BYTE* base = (BYTE*)GetModuleHandleA(nullptr);
    IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)base;
    IMAGE_NT_HEADERS* nt = (IMAGE_NT_HEADERS*)(base + dos->e_lfanew);
    IMAGE_SECTION_HEADER* sec = IMAGE_FIRST_SECTION(nt);
    size_t ml = strlen(marker);
    for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; i++) {
        if (memcmp(sec[i].Name, ".goo", 4) != 0) continue;
        BYTE* p = base + sec[i].VirtualAddress; DWORD len = sec[i].Misc.VirtualSize;
        for (DWORD k = 0; k + ml < len; k++) if (memcmp(p + k, marker, ml) == 0) return p + k;
    }
    return nullptr;
}
static DWORD* g_debug_word = nullptr;
static DWORD* g_stats = nullptr;      // GOO4KSTATS counters in the exe (see cave.s)
static bool g_f5_down = false;
static void poll_debug_keys() {
    if (!g_debug_keys) return;
    if (!g_debug_word) { BYTE* m = find_goo_marker("GOO4KDEBUG"); if (!m) return; g_debug_word = (DWORD*)(m + 12); }
    if (!g_stats) { BYTE* m = find_goo_marker("GOO4KSTATS"); if (m) g_stats = (DWORD*)(m + 12); }
    if (*g_debug_word >= 2) { logf("debug burst result %lu (2 no camera, 3 create failed, 4 created only, 5 added to scene)", *g_debug_word); *g_debug_word = 0; }
    bool down = (GetAsyncKeyState(VK_F5) & 0x8000) != 0;
    if (down && !g_f5_down) { *g_debug_word = 1; logf("F5: debug burst"); }
    g_f5_down = down;
    static DWORD last[7] = {0}; static unsigned n = 0;
    if (g_stats && (++n % 120) == 0 && memcmp(g_stats, last, sizeof last) != 0) { memcpy(last, g_stats, sizeof last); logf("font stats: marked=%lu uploads=%lu mipmapped=%lu draws=%lu anim_holds=%lu last_hold_rate=%.4f hold_hist(<.2 <.3 <.5 <1 <2 <5 <20 >=20)=%lu %lu %lu %lu %lu %lu %lu %lu neg_holds=%lu", g_stats[0], g_stats[1], g_stats[2], g_stats[4], g_stats[5], *(float*)&g_stats[6], g_stats[9], g_stats[10], g_stats[11], g_stats[12], g_stats[13], g_stats[14], g_stats[15], g_stats[16], g_stats[28]); }
}
static void apply_flags() {
    BYTE* m = find_goo_marker("GOO4KFLAGS");
    if (!m) { logf("no GOO4KFLAGS marker in exe"); return; }
    DWORD* flags = (DWORD*)(m + 12);
    if (g_interp_flags >= 0) *flags = (DWORD)g_interp_flags;
    logf("interp flags = %lu (1 bodies, 2 clock, 4 anims, 8 camera, 16 cursor, 32 particles, 64 font mipmaps)", *flags);
    if (BYTE* pm = find_goo_marker("GOO4KPAD")) { *(int*)(pm + 12) = g_font_pad < 0 ? 0 : g_font_pad; logf("font_pad = %d", g_font_pad); }
    if (BYTE* sm = find_goo_marker("GOO4KSOFT")) { *(int*)(sm + 12) = g_font_soften < 0 ? 0 : g_font_soften; logf("font_soften = %d", g_font_soften); }
    if (BYTE* wm = find_goo_marker("GOO4KWARM")) { *(int*)(wm + 12) = g_font_warm ? 1 : 0; logf("font_warm = %d", g_font_warm); }
}

static void find_exe_stamp(char* out, size_t n) {
    strcpy_s(out, n, "exe: no stamp");
    BYTE* base = (BYTE*)GetModuleHandleA(nullptr);
    IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)base;
    IMAGE_NT_HEADERS* nt = (IMAGE_NT_HEADERS*)(base + dos->e_lfanew);
    IMAGE_SECTION_HEADER* sec = IMAGE_FIRST_SECTION(nt);
    for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; i++) {
        if (memcmp(sec[i].Name, ".goo", 4) != 0) continue;
        BYTE* p = base + sec[i].VirtualAddress; DWORD len = sec[i].Misc.VirtualSize;
        for (DWORD k = 0; k + 6 < len; k++) {
            if (memcmp(p + k, "GOO4K:", 6) == 0) { strncpy_s(out, n, (char*)p + k + 6, _TRUNCATE); return; }
        }
    }
}

static void overlay_init_text() {
    char stamp[128]; find_exe_stamp(stamp, sizeof stamp);
    BYTE* m = find_goo_marker("GOO4KFLAGS"); DWORD fl = m ? *(DWORD*)(m + 12) : 0;
    char buf[256]; snprintf(buf, sizeof buf, "goo-4k  exe %s   shim %s %s   interp=%lu", stamp, __DATE__, __TIME__, fl);
    MultiByteToWideChar(CP_ACP, 0, buf, -1, g_text, 256);
    logf("overlay: %s", buf);
}

static void overlay_destroy() {
    if (g_brush) { g_brush->Release(); g_brush = nullptr; }
    if (g_rt) { g_rt->Release(); g_rt = nullptr; }
}

static void overlay_create() {
    if (!g_overlay || !g_shared) return;
    if (!g_d2d && FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory), nullptr, (void**)&g_d2d))) { logf("D2D factory failed"); g_overlay = false; return; }
    if (!g_dw && FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), (IUnknown**)&g_dw))) { logf("DWrite factory failed"); g_overlay = false; return; }
    if (!g_fmt) { g_dw->CreateTextFormat(L"Consolas", nullptr, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 22.0f, L"", &g_fmt); overlay_init_text(); }
    IDXGISurface* surf = nullptr;
    if (FAILED(g_shared->QueryInterface(__uuidof(IDXGISurface), (void**)&surf))) return;
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 96.0f, 96.0f);
    HRESULT hr = g_d2d->CreateDxgiSurfaceRenderTarget(surf, &props, &g_rt);
    surf->Release();
    if (FAILED(hr)) { logf("D2D render target failed %08lx", hr); g_overlay = false; return; }
    g_rt->CreateSolidColorBrush(D2D1::ColorF(1.0f, 1.0f, 0.4f, 0.9f), &g_brush);
}

static void overlay_draw() {
    if (!g_rt || !g_fmt || !g_brush) return;
    g_rt->BeginDraw();
    D2D1_RECT_F rc = D2D1::RectF(12.0f, 8.0f, 1400.0f, 40.0f);
    g_rt->DrawText(g_text, (UINT32)wcslen(g_text), g_fmt, rc, g_brush);
    g_rt->EndDraw();
}

static void destroy_shared() {
    overlay_destroy();
    if (g_sharedH) { p_wglDXUnregisterObjectNV(g_interop, g_sharedH); g_sharedH = nullptr; }
    if (g_fbo) { p_glDeleteFramebuffers(1, &g_fbo); g_fbo = 0; }
    if (g_tex) { glDeleteTextures(1, &g_tex); g_tex = 0; }
    if (g_shared) { g_shared->Release(); g_shared = nullptr; }
}

static bool create_shared(int w, int h) {
    D3D11_TEXTURE2D_DESC td = {};
    td.Width = w; td.Height = h; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    if (FAILED(g_dev->CreateTexture2D(&td, nullptr, &g_shared))) { logf("CreateTexture2D failed"); return false; }
    { ID3D11RenderTargetView* rtv = nullptr;          // fresh video memory is undefined; start from black
      if (SUCCEEDED(g_dev->CreateRenderTargetView(g_shared, nullptr, &rtv))) { const float black[4] = {0, 0, 0, 1}; g_ctx->ClearRenderTargetView(rtv, black); rtv->Release(); } }
    glGenTextures(1, &g_tex);
    g_sharedH = p_wglDXRegisterObjectNV(g_interop, g_shared, g_tex, GL_TEXTURE_2D, WGL_ACCESS_WRITE_DISCARD_NV);
    if (!g_sharedH) { logf("wglDXRegisterObjectNV failed (%lu)", GetLastError()); return false; }
    p_glGenFramebuffers(1, &g_fbo);
    overlay_create();
    return true;
}

static bool resize(int w, int h) {
    destroy_shared();
    HRESULT hr = g_sc->ResizeBuffers(0, w, h, DXGI_FORMAT_UNKNOWN, g_tearing ? DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING : 0);
    if (FAILED(hr)) { logf("ResizeBuffers failed %08lx", hr); return false; }
    g_w = w; g_h = h;
    return create_shared(w, h);
}

static bool init_present() {
    HDC hdc = wglGetCurrentDC();
    if (!hdc || !wglGetCurrentContext()) { logf("no current GL context at first swap"); return false; }
    g_hwnd = WindowFromDC(hdc);
    if (!g_hwnd) { logf("WindowFromDC failed"); return false; }
    bool ok = true;
    ok &= gl_load(p_glGenFramebuffers, "glGenFramebuffers");
    ok &= gl_load(p_glDeleteFramebuffers, "glDeleteFramebuffers");
    ok &= gl_load(p_glBindFramebuffer, "glBindFramebuffer");
    ok &= gl_load(p_glFramebufferTexture2D, "glFramebufferTexture2D");
    ok &= gl_load(p_glBlitFramebuffer, "glBlitFramebuffer");
    ok &= gl_load(p_glCheckFramebufferStatus, "glCheckFramebufferStatus");
    ok &= gl_load(p_wglDXOpenDeviceNV, "wglDXOpenDeviceNV");
    ok &= gl_load(p_wglDXCloseDeviceNV, "wglDXCloseDeviceNV");
    ok &= gl_load(p_wglDXRegisterObjectNV, "wglDXRegisterObjectNV");
    ok &= gl_load(p_wglDXUnregisterObjectNV, "wglDXUnregisterObjectNV");
    ok &= gl_load(p_wglDXLockObjectsNV, "wglDXLockObjectsNV");
    ok &= gl_load(p_wglDXUnlockObjectsNV, "wglDXUnlockObjectsNV");
    if (!ok) return false;

    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    D3D_FEATURE_LEVEL fl;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, nullptr, 0, D3D11_SDK_VERSION, &g_dev, &fl, &g_ctx);
    if (FAILED(hr)) { logf("D3D11CreateDevice failed %08lx", hr); return false; }
    IDXGIDevice* dxdev = nullptr; IDXGIAdapter* adapter = nullptr; IDXGIFactory2* factory = nullptr;
    g_dev->QueryInterface(__uuidof(IDXGIDevice), (void**)&dxdev);
    dxdev->GetAdapter(&adapter);
    adapter->GetParent(__uuidof(IDXGIFactory2), (void**)&factory);
    IDXGIFactory5* f5 = nullptr; BOOL tearing = FALSE;
    if (SUCCEEDED(factory->QueryInterface(__uuidof(IDXGIFactory5), (void**)&f5))) {
        f5->CheckFeatureSupport(DXGI_FEATURE_PRESENT_ALLOW_TEARING, &tearing, sizeof(tearing)); f5->Release();
    }
    g_tearing = tearing != FALSE;

    RECT rc; GetClientRect(g_hwnd, &rc);
    g_w = rc.right - rc.left; g_h = rc.bottom - rc.top;
    DXGI_SWAP_CHAIN_DESC1 sd = {};
    sd.Width = g_w; sd.Height = g_h; sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 3; sd.Scaling = DXGI_SCALING_NONE; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    sd.AlphaMode = DXGI_ALPHA_MODE_IGNORE; sd.Flags = g_tearing ? DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING : 0;
    hr = factory->CreateSwapChainForHwnd(g_dev, g_hwnd, &sd, nullptr, nullptr, &g_sc);
    if (FAILED(hr)) { logf("CreateSwapChainForHwnd failed %08lx", hr); return false; }
    factory->MakeWindowAssociation(g_hwnd, DXGI_MWA_NO_ALT_ENTER | DXGI_MWA_NO_WINDOW_CHANGES);
    factory->Release(); adapter->Release(); dxdev->Release();

    g_interop = p_wglDXOpenDeviceNV(g_dev);
    if (!g_interop) { logf("wglDXOpenDeviceNV failed (%lu)", GetLastError()); return false; }
    if (!create_shared(g_w, g_h)) return false;
    logf("present: hwnd %p %dx%d tearing=%d fl=%x", (void*)g_hwnd, g_w, g_h, (int)g_tearing, (unsigned)fl);
    return true;
}

// save the frame about to be presented as a 32-bit BMP next to the log (ini dump_frames=N)
static void dump_frame(unsigned idx) {
    ID3D11Texture2D* bb = nullptr; if (FAILED(g_sc->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&bb))) return;
    D3D11_TEXTURE2D_DESC td; bb->GetDesc(&td); td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ; td.MiscFlags = 0;
    ID3D11Texture2D* st = nullptr;
    if (SUCCEEDED(g_dev->CreateTexture2D(&td, nullptr, &st))) {
        g_ctx->CopyResource(st, bb);
        D3D11_MAPPED_SUBRESOURCE mp;
        if (SUCCEEDED(g_ctx->Map(st, 0, D3D11_MAP_READ, 0, &mp))) {
            char path[MAX_PATH]; snprintf(path, sizeof path, "%s\\2DBoy\\WorldOfGoo\\frame%03u.bmp", getenv("LOCALAPPDATA") ? getenv("LOCALAPPDATA") : ".", idx);
            if (FILE* f = fopen(path, "wb")) {
                unsigned w = td.Width, h = td.Height, rowbytes = w * 4, size = rowbytes * h;
                unsigned char hdr[54] = {'B','M'}; auto put32 = [&](int off, unsigned v) { hdr[off] = v; hdr[off+1] = v >> 8; hdr[off+2] = v >> 16; hdr[off+3] = v >> 24; };
                put32(2, 54 + size); put32(10, 54); put32(14, 40); put32(18, w); put32(22, h); hdr[26] = 1; hdr[28] = 32; put32(34, size);
                fwrite(hdr, 1, 54, f);
                for (int y = (int)h - 1; y >= 0; y--) fwrite((const char*)mp.pData + (size_t)y * mp.RowPitch, 1, rowbytes, f);
                fclose(f);
            }
            g_ctx->Unmap(st, 0);
        }
        st->Release();
    }
    bb->Release();
}

static void present_frame() {
    RECT rc; GetClientRect(g_hwnd, &rc);
    int w = rc.right - rc.left, h = rc.bottom - rc.top;
    if (w <= 0 || h <= 0) return;                       // minimized
    if (w != g_w || h != g_h) { if (!resize(w, h)) { g_disabled = true; return; } logf("resized %dx%d", w, h); }

    // frame timing: log slow frames with what the exe did in them (debug only)
    static LARGE_INTEGER t0 = {}, tprev = {}, tfreq = {}; LARGE_INTEGER tnow; QueryPerformanceCounter(&tnow);
    if (!tfreq.QuadPart) { QueryPerformanceFrequency(&tfreq); t0 = tprev = tnow; }
    static DWORD sprev[7] = {0}; static unsigned long long uplprev = 0, softprev = 0, mipprev = 0;
    if (g_debug_keys && g_frames > 10) {
        double ms = (tnow.QuadPart - tprev.QuadPart) * 1000.0 / tfreq.QuadPart;
        if (ms > 25.0) {
            DWORD d[7] = {0}; if (g_stats) for (int i = 0; i < 6; i++) d[i] = g_stats[i] - sprev[i];
            double upms = g_stats ? (double)(*(unsigned long long*)&g_stats[7] - uplprev) * 1000.0 / tfreq.QuadPart : 0;
            double softms = g_stats ? (double)(*(unsigned long long*)&g_stats[29] - softprev) * 1000.0 / tfreq.QuadPart : 0;
            double mipms = g_stats ? (double)(*(unsigned long long*)&g_stats[31] - mipprev) * 1000.0 / tfreq.QuadPart : 0;
            logf("slow frame %.1f ms at %.1f s: glyph_uploads+%lu (%.1f ms total: soften %.1f, mipmaps %.1f) draws+%lu anim_holds+%lu", ms, (tnow.QuadPart - t0.QuadPart) / (double)tfreq.QuadPart, d[1], upms, softms, mipms, d[4], d[5]);
        }
    }
    if (g_stats) { memcpy(sprev, g_stats, sizeof sprev); uplprev = *(unsigned long long*)&g_stats[7]; softprev = *(unsigned long long*)&g_stats[29]; mipprev = *(unsigned long long*)&g_stats[31]; }
    tprev = tnow;

    // the GL drawable can lag the client rect for a frame or two around resizes; never read past it
    int dw = w, dh = h;
    if (real_GetDrawableSize && g_win) real_GetDrawableSize(g_win, &dw, &dh);
    static int lastdw = 0, lastdh = 0;
    if ((dw != w || dh != h) && (dw != lastdw || dh != lastdh)) { logf("drawable %dx%d vs client %dx%d", dw, dh, w, h); lastdw = dw; lastdh = dh; }
    int bw = dw < w ? dw : w, bh = dh < h ? dh : h;

    // GL: copy the window back buffer into the shared texture (flip Y for D3D)
    if (!p_wglDXLockObjectsNV(g_interop, 1, &g_sharedH)) { logf("lock failed"); return; }
    GLint prevRead = 0, prevDraw = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead); glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevDraw);
    p_glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g_fbo);
    p_glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g_tex, 0);
    if (bw != w || bh != h) {   // partial frame: black outside the drawable
        GLfloat cc0[4]; GLboolean cm0[4]; glGetFloatv(GL_COLOR_CLEAR_VALUE, cc0); glGetBooleanv(GL_COLOR_WRITEMASK, cm0);
        GLboolean sc0 = glIsEnabled(GL_SCISSOR_TEST); if (sc0) glDisable(GL_SCISSOR_TEST);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE); glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
        glColorMask(cm0[0], cm0[1], cm0[2], cm0[3]); glClearColor(cc0[0], cc0[1], cc0[2], cc0[3]); if (sc0) glEnable(GL_SCISSOR_TEST);
    }
    p_glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    glReadBuffer(GL_BACK);
    p_glBlitFramebuffer(0, 0, bw, bh, 0, h, bw, h - bh, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    {   // force alpha = 1: the game leaves translucent pixels in its back buffer (GL swap ignores them,
        // a flip-model swapchain in HDR mode can composite them and show the desktop through)
        GLfloat cc[4]; GLboolean cm[4]; glGetFloatv(GL_COLOR_CLEAR_VALUE, cc); glGetBooleanv(GL_COLOR_WRITEMASK, cm);
        GLboolean sc = glIsEnabled(GL_SCISSOR_TEST); if (sc) glDisable(GL_SCISSOR_TEST);
        glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_TRUE); glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
        glColorMask(cm[0], cm[1], cm[2], cm[3]); glClearColor(cc[0], cc[1], cc[2], cc[3]); if (sc) glEnable(GL_SCISSOR_TEST);
    }
    p_glBindFramebuffer(GL_READ_FRAMEBUFFER, prevRead); p_glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prevDraw);
    p_wglDXUnlockObjectsNV(g_interop, 1, &g_sharedH);
    overlay_draw();

    // D3D: shared -> back buffer, present
    ID3D11Texture2D* bb = nullptr;
    if (SUCCEEDED(g_sc->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&bb))) {
        g_ctx->CopyResource(bb, g_shared); bb->Release();
    }
    poll_debug_keys();
    wait_for_cap();
    UINT sync = (g_interval == 0) ? 0 : 1;
    UINT flags = (sync == 0 && g_tearing) ? DXGI_PRESENT_ALLOW_TEARING : 0;
    if (g_frames < (unsigned)g_dump_frames) dump_frame(g_frames);
    HRESULT hr = g_sc->Present(sync, flags);
    static HRESULT lasthr = S_OK;
    if (hr != lasthr) { logf("Present status %08lx at frame %lu", hr, (unsigned long)g_frames); lasthr = hr; }
    if (FAILED(hr)) { if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) g_disabled = true; }
    if (++g_frames == 1) logf("first frame presented");
}

extern "C" {

__declspec(dllexport) void SDL_GL_SwapWindow(SDL_Window* win) {
    load_real();
    g_win = win;
    if (getenv("GOO_PRESENT_OFF")) g_disabled = true;
    if (!g_disabled && !g_inited) { g_inited = true; read_settings(); if (!init_present()) { g_disabled = true; logf("present disabled, using GL swap"); } }
    if (g_disabled) { if (real_SwapWindow) real_SwapWindow(win); return; }
    present_frame();
}

__declspec(dllexport) int SDL_GL_SetSwapInterval(int interval) {
    load_real();
    g_interval = interval;
    logf("SetSwapInterval(%d)", interval);
    return real_SetSwapInterval ? real_SetSwapInterval(interval) : 0;
}

__declspec(dllexport) int SDL_GL_GetSwapInterval(void) {
    load_real();
    return real_GetSwapInterval ? real_GetSwapInterval() : g_interval;
}

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) load_real();
    return TRUE;
}

}
