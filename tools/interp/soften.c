/* Glyph edge softening, called from upload_hook (cave.s) before the engine uploads a glyph texture.
 *
 * Widens the alpha ramp at the glyph's outer edge by a box blur of radius r texels (RGB is untouched
 * inside the opaque area, so the fill/outline boundary stays as FreeType drew it) and extends the
 * edge colour into the newly covered transparent texels, so the wider alpha does not blend in black.
 * Needs the bitmap pad (margin_hook) for room. The ramp stays linear in alpha.
 *
 * Freestanding: no libc, no static data (the .goo section only carries .text). Integer math only.
 * Separable running-sum blur: about 4 passes over the plane, no per-texel division or bounds tests.
 * Built by build.py with gcc and linked into the cave; Win64 ABI.
 */
typedef unsigned char u8;
typedef unsigned long long usz;

void glyph_soften(u8* px, int size, int r, void* (*alloc)(usz), void (*release)(void*)) {
    if (!px || size <= 0 || r <= 0 || r > 16 || size > 8192) return;
    int n = size, w = 2 * r + 1;
    usz plane = (usz)n * n;
    /* a0: original alpha; h: horizontally blurred alpha; col: running column sums; lut: s -> s/w */
    u8* mem = (u8*)alloc(plane * 2 + (usz)n * sizeof(int) + (usz)255 * w + 1);
    if (!mem) return;
    u8* a0 = mem; u8* h = mem + plane; int* col = (int*)(h + plane); u8* lut = (u8*)(col + n);
    for (int s = 0, q = 0, c = 0; s <= 255 * w; s++) { lut[s] = (u8)q; if (++c == w) { c = 0; q++; } }

    /* pass 1: copy alpha and find the coverage bounding box; everything else stays transparent */
    int bx0 = n, bx1 = -1, by0 = n, by1 = -1;
    for (int y = 0; y < n; y++) {
        const u8* src = px + (usz)y * n * 4 + 3; u8* dst = a0 + (usz)y * n; int rowany = 0;
        for (int x = 0; x < n; x++) { u8 a = src[x * 4]; dst[x] = a; if (a) { rowany = 1; if (x < bx0) bx0 = x; if (x > bx1) bx1 = x; } }
        if (rowany) { if (y < by0) by0 = y; by1 = y; }
    }
    if (bx1 < 0) { release(mem); return; }
    /* work window: bbox grown by the radius, clamped to the bitmap */
    int wx0 = bx0 - r < 0 ? 0 : bx0 - r, wx1 = bx1 + r >= n ? n - 1 : bx1 + r;
    int wy0 = by0 - r < 0 ? 0 : by0 - r, wy1 = by1 + r >= n ? n - 1 : by1 + r;

    /* pass 2: horizontal box sum per row (edges clamp to 0), h = sum / w, rows of the window only */
    for (int y = wy0; y <= wy1; y++) {
        const u8* src = a0 + (usz)y * n; u8* dst = h + (usz)y * n;
        int s = 0;
        for (int x = wx0 - r; x < wx0 + r; x++) if (x >= 0 && x < n) s += src[x];
        for (int x = wx0; x <= wx1; x++) {
            int add = x + r, rem = x - r - 1;
            if (add < n) s += src[add];
            if (rem >= 0) s -= src[rem];
            dst[x] = lut[s];
        }
    }
    /* pass 3: vertical box sum per column with a running row window, written to the alpha channel */
    for (int x = wx0; x <= wx1; x++) col[x] = 0;
    for (int y = wy0 - r; y < wy0 + r; y++) if (y >= wy0 && y <= wy1) { const u8* row = h + (usz)y * n; for (int x = wx0; x <= wx1; x++) col[x] += row[x]; }
    for (int y = wy0; y <= wy1; y++) {
        int add = y + r, rem = y - r - 1;
        if (add <= wy1) { const u8* row = h + (usz)add * n; for (int x = wx0; x <= wx1; x++) col[x] += row[x]; }
        if (rem >= wy0) { const u8* row = h + (usz)rem * n; for (int x = wx0; x <= wx1; x++) col[x] -= row[x]; }
        u8* out = px + (usz)y * n * 4 + 3;
        for (int x = wx0; x <= wx1; x++) out[x * 4] = lut[col[x]];
    }
    /* pass 4: colour extension for texels that were transparent and are now covered: the coverage-
       weighted mean colour of the window (weights from the original alpha) */
    for (int y = wy0; y <= wy1; y++) {
        int y0 = y - r < 0 ? 0 : y - r, y1 = y + r >= n ? n - 1 : y + r;
        u8* row = px + (usz)y * n * 4;
        for (int x = wx0; x <= wx1; x++) {
            if (a0[(usz)y * n + x] || !row[x * 4 + 3]) continue;
            unsigned sr = 0, sg = 0, sb = 0, sa = 0;
            int x0 = x - r < 0 ? 0 : x - r, x1 = x + r >= n ? n - 1 : x + r;
            for (int yy = y0; yy <= y1; yy++) {
                const u8* p = px + ((usz)yy * n + x0) * 4; const u8* pa = a0 + (usz)yy * n + x0;
                for (int xx = x0; xx <= x1; xx++, p += 4, pa++) {
                    unsigned a = *pa;
                    if (a) { sr += p[0] * a; sg += p[1] * a; sb += p[2] * a; sa += a; }
                }
            }
            if (sa) { row[x * 4] = (u8)(sr / sa); row[x * 4 + 1] = (u8)(sg / sa); row[x * 4 + 2] = (u8)(sb / sa); }
        }
    }
    release(mem);
}
