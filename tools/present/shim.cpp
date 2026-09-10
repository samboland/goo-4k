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
static HMODULE g_real = nullptr;

static void load_real() {
    if (g_real) return;
    g_real = LoadLibraryA("SDL2_real.dll");
    if (!g_real) { logf("SDL2_real.dll not found"); return; }
    real_SwapWindow = (PFN_SwapWindow)GetProcAddress(g_real, "SDL_GL_SwapWindow");
    real_SetSwapInterval = (PFN_SetSwapInterval)GetProcAddress(g_real, "SDL_GL_SetSwapInterval");
    real_GetSwapInterval = (PFN_GetSwapInterval)GetProcAddress(g_real, "SDL_GL_GetSwapInterval");
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
static double   g_cap_period = 0;      // seconds per frame when fps_cap is set
static LARGE_INTEGER g_qpf = {}, g_last_present = {};

// goopresent.ini next to the config: fps_cap=<n> (0 = off). Env GOO_FPS_CAP overrides.
static void read_settings() {
    double cap = 0;
    char path[MAX_PATH]; DWORD n = GetEnvironmentVariableA("LOCALAPPDATA", path, MAX_PATH);
    if (n && n < MAX_PATH) {
        strcat_s(path, "\\2DBoy\\WorldOfGoo\\goopresent.ini");
        if (FILE* f = fopen(path, "r")) { char line[256]; while (fgets(line, sizeof line, f)) { double v; int o; if (sscanf(line, " fps_cap = %lf", &v) == 1 || sscanf(line, " fps_cap=%lf", &v) == 1) cap = v; if (sscanf(line, " overlay = %d", &o) == 1 || sscanf(line, " overlay=%d", &o) == 1) g_overlay = o != 0; } fclose(f); }
    }
    if (const char* e = getenv("GOO_FPS_CAP")) cap = atof(e);
    g_cap_period = cap > 0 ? 1.0 / cap : 0;
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
static bool g_overlay = true;
static ID2D1Factory* g_d2d = nullptr;
static IDWriteFactory* g_dw = nullptr;
static IDWriteTextFormat* g_fmt = nullptr;
static ID2D1RenderTarget* g_rt = nullptr;
static ID2D1SolidColorBrush* g_brush = nullptr;
static wchar_t g_text[256] = L"";

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
    char buf[256]; snprintf(buf, sizeof buf, "goo-4k  exe %s   shim %s %s", stamp, __DATE__, __TIME__);
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
    g_rt->DrawTextW(g_text, (UINT32)wcslen(g_text), g_fmt, rc, g_brush);
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

static void present_frame() {
    RECT rc; GetClientRect(g_hwnd, &rc);
    int w = rc.right - rc.left, h = rc.bottom - rc.top;
    if (w <= 0 || h <= 0) return;                       // minimized
    if (w != g_w || h != g_h) { if (!resize(w, h)) { g_disabled = true; return; } logf("resized %dx%d", w, h); }

    // GL: copy the window back buffer into the shared texture (flip Y for D3D)
    if (!p_wglDXLockObjectsNV(g_interop, 1, &g_sharedH)) { logf("lock failed"); return; }
    GLint prevRead = 0, prevDraw = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead); glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevDraw);
    p_glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g_fbo);
    p_glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g_tex, 0);
    p_glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    glReadBuffer(GL_BACK);
    p_glBlitFramebuffer(0, 0, w, h, 0, h, w, 0, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    p_glBindFramebuffer(GL_READ_FRAMEBUFFER, prevRead); p_glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prevDraw);
    p_wglDXUnlockObjectsNV(g_interop, 1, &g_sharedH);
    overlay_draw();

    // D3D: shared -> back buffer, present
    ID3D11Texture2D* bb = nullptr;
    if (SUCCEEDED(g_sc->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&bb))) {
        g_ctx->CopyResource(bb, g_shared); bb->Release();
    }
    wait_for_cap();
    UINT sync = (g_interval == 0) ? 0 : 1;
    UINT flags = (sync == 0 && g_tearing) ? DXGI_PRESENT_ALLOW_TEARING : 0;
    HRESULT hr = g_sc->Present(sync, flags);
    if (FAILED(hr)) { logf("Present failed %08lx", hr); if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) g_disabled = true; }
    if (++g_frames == 1) logf("first frame presented");
}

extern "C" {

__declspec(dllexport) void SDL_GL_SwapWindow(SDL_Window* win) {
    load_real();
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
