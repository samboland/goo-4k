/* Glyph edge softening, called from upload_hook (cave.s) before the engine uploads a glyph texture.
 *
 * The engine draws text with alpha blending in sRGB space, so a linear coverage ramp on a dark
 * outline over a light background looks heavy: 50% coverage reads as ~75% black. This widens the
 * alpha ramp at the glyph's outer edge by a box blur of radius r texels (RGB is untouched inside
 * the opaque area, so the fill/outline boundary stays sharp), extends the edge colour into the
 * newly covered transparent texels, and reshapes alpha with a gamma-2 curve so mid coverage
 * reads as mid grey.
 *
 * Freestanding: no libc, no static data (the .goo section only carries .text). Integer math only.
 * Built by build.py with gcc and linked into the cave; Win64 ABI.
 */
typedef unsigned char u8;
typedef unsigned long long usz;

void glyph_soften(u8* px, int size, int r, void* (*alloc)(usz), void (*release)(void*)) {
    if (!px || size <= 0 || r <= 0 || r > 16 || size > 8192) return;
    int n = size;
    usz plane = (usz)n * n;
    /* orig alpha copy + per-row bounds + blur temp + LUT */
    u8* a0 = (u8*)alloc(plane + (usz)n * 8 + 256);
    if (!a0) return;
    int* rmin = (int*)(a0 + plane);
    int* rmax = rmin + n;
    u8* lut = (u8*)(rmax + n);

    /* gamma-2 reshape LUT: a' = 255 - sqrt((255 - a) * 255) */
    for (int a = 0; a < 256; a++) {
        unsigned v = (unsigned)(255 - a) * 255u, s = 0, bit = 1u << 14;
        while (bit > v) bit >>= 2;
        while (bit) { if (v >= s + bit) { v -= s + bit; s = (s >> 1) + bit; } else s >>= 1; bit >>= 2; }
        lut[a] = (u8)(255 - (int)s);
    }

    for (int y = 0; y < n; y++) {
        u8* row = px + (usz)y * n * 4;
        int lo = n, hi = -1;
        for (int x = 0; x < n; x++) {
            u8 a = row[x * 4 + 3];
            a0[(usz)y * n + x] = a;
            if (a) { if (x < lo) lo = x; hi = x; }
        }
        rmin[y] = lo; rmax[y] = hi;
    }

    /* colour extension: transparent texels within r of coverage take the coverage-weighted
       average colour of their window, so the widened alpha does not blend in black fringes */
    for (int y = 0; y < n; y++) {
        int y0 = y - r < 0 ? 0 : y - r, y1 = y + r >= n ? n - 1 : y + r;
        int lo = n, hi = -1;
        for (int yy = y0; yy <= y1; yy++) { if (rmin[yy] < lo) lo = rmin[yy]; if (rmax[yy] > hi) hi = rmax[yy]; }
        if (hi < 0) continue;
        u8* row = px + (usz)y * n * 4;
        int xs = lo - r < 0 ? 0 : lo - r, xe = hi + r >= n ? n - 1 : hi + r;
        for (int x = xs; x <= xe; x++) {
            if (a0[(usz)y * n + x]) continue;
            unsigned sr = 0, sg = 0, sb = 0, sa = 0;
            int x0 = x - r < 0 ? 0 : x - r, x1 = x + r >= n ? n - 1 : x + r;
            for (int yy = y0; yy <= y1; yy++) {
                if (x1 < rmin[yy] || x0 > rmax[yy]) continue;
                const u8* p = px + ((usz)yy * n + x0) * 4;
                for (int xx = x0; xx <= x1; xx++, p += 4) {
                    unsigned a = p[3];
                    if (a) { sr += p[0] * a; sg += p[1] * a; sb += p[2] * a; sa += a; }
                }
            }
            if (sa) { row[x * 4] = (u8)(sr / sa); row[x * 4 + 1] = (u8)(sg / sa); row[x * 4 + 2] = (u8)(sb / sa); }
        }
    }

    /* separable box blur of alpha, in place, only over rows/cols that can change */
    int w = 2 * r + 1;
    for (int y = 0; y < n; y++) {
        if (rmax[y] < 0) continue;
        u8* row = px + (usz)y * n * 4;
        const u8* src = a0 + (usz)y * n;
        int xs = rmin[y] - r < 0 ? 0 : rmin[y] - r, xe = rmax[y] + r >= n ? n - 1 : rmax[y] + r;
        for (int x = xs; x <= xe; x++) {
            int x0 = x - r, x1 = x + r; unsigned s = 0;
            for (int xx = x0; xx <= x1; xx++) if (xx >= 0 && xx < n) s += src[xx];
            row[x * 4 + 3] = (u8)(s / (unsigned)w);
        }
    }
    /* vertical pass reads the horizontally blurred alpha; a0 becomes the temp copy */
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) a0[(usz)y * n + x] = px[((usz)y * n + x) * 4 + 3];
    for (int x = 0; x < n; x++) {
        for (int y = 0; y < n; y++) {
            int y0 = y - r, y1 = y + r; unsigned s = 0; int any = 0;
            for (int yy = y0; yy <= y1; yy++) if (yy >= 0 && yy < n) { unsigned v = a0[(usz)yy * n + x]; s += v; any |= v; }
            if (!any) continue;
            px[((usz)y * n + x) * 4 + 3] = lut[s / (unsigned)w];
        }
    }
    release(a0);
}
