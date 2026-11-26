#include "VGSGifWriter.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    kBins = 32768,              // 5 bits each of red, green and blue
    kMaxColors = 255,           // one slot of 256 stays free for "see-through"
    kHashBits = 14,
    kHashSize = 1 << kHashBits,
};

typedef struct { uint32_t count, r, g, b; } VGSBin;                    // sums of the 8-bit values
typedef struct { uint32_t count; uint8_t r, g, b; uint16_t bin; } VGSEntry;   // one colour in use, averaged
typedef struct { int lo, hi, axis; double mean, score; } VGSBox;

struct VGSGifWriter {
    FILE *file;
    int width, height, tolerance, dither;
    int frames;
    int failed;
    long long bytes;
    uint8_t *ref;               // per pixel: the source colour when it was last drawn (r, g, b)
    uint8_t *indexes;           // first the "changed" mask, then the palette indexes of the frame's rectangle
    VGSBin *bins;
    VGSEntry *entries;
    int16_t *lut;               // bin -> palette index, -1 when not worked out yet
    uint8_t palette[256 * 3];
    int paletteCount;
    int *errors;                // dithering: two rows of (width + 2) * 3
    int32_t *hashKeys;
    uint16_t *hashValues;
    uint8_t block[255];
    int blockLength;
    uint32_t bitBuffer;
    int bitCount;
};

#pragma mark - Output

static void gs_write(VGSGifWriter *w, const void *data, size_t length) {
    if (w->failed) return;
    if (fwrite(data, 1, length, w->file) != length) w->failed = 1;
    w->bytes += (long long)length;
}

static void gs_byte(VGSGifWriter *w, int value) {
    uint8_t b = (uint8_t)value;
    gs_write(w, &b, 1);
}

static void gs_word(VGSGifWriter *w, int value) {
    uint8_t b[2] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF) };
    gs_write(w, b, 2);
}

#pragma mark - LZW

static void gs_block_byte(VGSGifWriter *w, int value) {
    w->block[w->blockLength++] = (uint8_t)value;
    if (w->blockLength == 255) {
        gs_byte(w, 255);
        gs_write(w, w->block, 255);
        w->blockLength = 0;
    }
}

static void gs_code(VGSGifWriter *w, int code, int size) {
    w->bitBuffer |= (uint32_t)code << w->bitCount;
    w->bitCount += size;
    while (w->bitCount >= 8) {
        gs_block_byte(w, (int)(w->bitBuffer & 0xFF));
        w->bitBuffer >>= 8;
        w->bitCount -= 8;
    }
}

static void gs_lzw(VGSGifWriter *w, const uint8_t *data, size_t count, int minCodeSize) {
    const int clearCode = 1 << minCodeSize;
    const int endCode = clearCode + 1;
    int nextCode = endCode + 1;
    int size = minCodeSize + 1;
    const uint32_t mask = kHashSize - 1;

    gs_byte(w, minCodeSize);
    w->blockLength = 0;
    w->bitBuffer = 0;
    w->bitCount = 0;
    memset(w->hashKeys, 0xFF, sizeof(int32_t) * kHashSize);
    gs_code(w, clearCode, size);

    int current = data[0];
    for (size_t i = 1; i < count; i++) {
        const int next = data[i];
        const int32_t key = (int32_t)((current << 8) | next);
        uint32_t slot = ((uint32_t)key * 2654435761u) >> (32 - kHashBits);
        int found = -1;
        while (w->hashKeys[slot] != -1) {
            if (w->hashKeys[slot] == key) { found = w->hashValues[slot]; break; }
            slot = (slot + 1) & mask;
        }
        if (found >= 0) { current = found; continue; }

        gs_code(w, current, size);
        if (nextCode == 4096) {
            // The table is full: start over.
            gs_code(w, clearCode, size);
            memset(w->hashKeys, 0xFF, sizeof(int32_t) * kHashSize);
            nextCode = endCode + 1;
            size = minCodeSize + 1;
        } else {
            w->hashKeys[slot] = key;
            w->hashValues[slot] = (uint16_t)nextCode;
            if (nextCode == (1 << size)) size++;
            nextCode++;
        }
        current = next;
    }
    gs_code(w, current, size);
    // A reader adds one more entry after the last code, and may widen its codes before the end code.
    if (nextCode == (1 << size) && size < 12) size++;
    gs_code(w, endCode, size);
    if (w->bitCount > 0) gs_block_byte(w, (int)(w->bitBuffer & 0xFF));
    if (w->blockLength > 0) {
        gs_byte(w, w->blockLength);
        gs_write(w, w->block, (size_t)w->blockLength);
        w->blockLength = 0;
    }
    gs_byte(w, 0);
}

#pragma mark - Palette

static inline int gs_channel(const VGSEntry *e, int axis) {
    return axis == 0 ? e->r : (axis == 1 ? e->g : e->b);
}

static void gs_measure(const VGSEntry *entries, VGSBox *box) {
    double n = 0, sum[3] = { 0, 0, 0 }, squares[3] = { 0, 0, 0 };
    for (int i = box->lo; i < box->hi; i++) {
        const VGSEntry *e = &entries[i];
        const double c = e->count;
        n += c;
        sum[0] += c * e->r; squares[0] += c * e->r * e->r;
        sum[1] += c * e->g; squares[1] += c * e->g * e->g;
        sum[2] += c * e->b; squares[2] += c * e->b * e->b;
    }
    box->score = 0;
    box->axis = 0;
    box->mean = 0;
    if (box->hi - box->lo < 2 || n <= 0) return;
    for (int axis = 0; axis < 3; axis++) {
        const double mean = sum[axis] / n;
        const double spread = squares[axis] - sum[axis] * mean;
        if (spread > box->score) {
            box->score = spread;
            box->axis = axis;
            box->mean = mean;
        }
    }
}

static int gs_nearest(const VGSGifWriter *w, int r, int g, int b) {
    int best = 0, bestDistance = 1 << 30;
    const uint8_t *p = w->palette;
    for (int i = 0; i < w->paletteCount; i++, p += 3) {
        const int dr = r - p[0], dg = g - p[1], db = b - p[2];
        const int distance = dr * dr + dg * dg + db * db;
        if (distance < bestDistance) { bestDistance = distance; best = i; }
    }
    return best;
}

// Turns the histogram into a palette and fills the lookup table for every colour that is in use.
static void gs_build_palette(VGSGifWriter *w) {
    VGSEntry *entries = w->entries;
    int count = 0;
    for (int bin = 0; bin < kBins; bin++) {
        const VGSBin *b = &w->bins[bin];
        if (!b->count) continue;
        VGSEntry *e = &entries[count++];
        e->count = b->count;
        e->r = (uint8_t)(b->r / b->count);
        e->g = (uint8_t)(b->g / b->count);
        e->b = (uint8_t)(b->b / b->count);
        e->bin = (uint16_t)bin;
    }
    memset(w->lut, 0xFF, sizeof(int16_t) * kBins);
    memset(w->palette, 0, sizeof(w->palette));

    if (count <= kMaxColors) {
        for (int i = 0; i < count; i++) {
            w->palette[i * 3] = entries[i].r;
            w->palette[i * 3 + 1] = entries[i].g;
            w->palette[i * 3 + 2] = entries[i].b;
            w->lut[entries[i].bin] = (int16_t)i;
        }
        w->paletteCount = count;
        return;
    }

    VGSBox boxes[kMaxColors];
    int boxCount = 1;
    boxes[0].lo = 0;
    boxes[0].hi = count;
    gs_measure(entries, &boxes[0]);
    while (boxCount < kMaxColors) {
        int best = -1;
        double bestScore = 0;
        for (int i = 0; i < boxCount; i++) {
            if (boxes[i].score > bestScore) { bestScore = boxes[i].score; best = i; }
        }
        if (best < 0) break;
        VGSBox *box = &boxes[best];
        int i = box->lo, j = box->hi - 1;
        while (i <= j) {
            if (gs_channel(&entries[i], box->axis) < box->mean) {
                i++;
            } else {
                const VGSEntry swap = entries[i];
                entries[i] = entries[j];
                entries[j] = swap;
                j--;
            }
        }
        if (i == box->lo || i == box->hi) { box->score = 0; continue; }
        boxes[boxCount].lo = i;
        boxes[boxCount].hi = box->hi;
        box->hi = i;
        gs_measure(entries, box);
        gs_measure(entries, &boxes[boxCount]);
        boxCount++;
    }

    for (int i = 0; i < boxCount; i++) {
        double n = 0, r = 0, g = 0, b = 0;
        for (int k = boxes[i].lo; k < boxes[i].hi; k++) {
            const double c = entries[k].count;
            n += c;
            r += c * entries[k].r;
            g += c * entries[k].g;
            b += c * entries[k].b;
        }
        if (n <= 0) n = 1;
        w->palette[i * 3] = (uint8_t)(r / n + 0.5);
        w->palette[i * 3 + 1] = (uint8_t)(g / n + 0.5);
        w->palette[i * 3 + 2] = (uint8_t)(b / n + 0.5);
    }
    w->paletteCount = boxCount;
    for (int i = 0; i < count; i++) {
        w->lut[entries[i].bin] = (int16_t)gs_nearest(w, entries[i].r, entries[i].g, entries[i].b);
    }
}

#pragma mark - Frames

static inline int gs_bin(int r, int g, int b) {
    return ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
}

static inline int gs_clamp(int v) {
    return v < 0 ? 0 : (v > 255 ? 255 : v);
}

VGSGifWriter *VGSGifWriterOpen(const char *path, int width, int height, int tolerance, int dither) {
    if (!path || width < 1 || height < 1 || width > 65535 || height > 65535) return NULL;
    VGSGifWriter *w = (VGSGifWriter *)calloc(1, sizeof(VGSGifWriter));
    if (!w) return NULL;
    const size_t pixels = (size_t)width * (size_t)height;
    w->width = width;
    w->height = height;
    w->tolerance = tolerance < 0 ? 0 : tolerance;
    w->dither = dither ? 1 : 0;
    w->ref = (uint8_t *)malloc(pixels * 3);
    w->indexes = (uint8_t *)malloc(pixels);
    w->bins = (VGSBin *)malloc(sizeof(VGSBin) * kBins);
    w->entries = (VGSEntry *)malloc(sizeof(VGSEntry) * kBins);
    w->lut = (int16_t *)malloc(sizeof(int16_t) * kBins);
    w->errors = (int *)calloc((size_t)(width + 2) * 3 * 2, sizeof(int));
    w->hashKeys = (int32_t *)malloc(sizeof(int32_t) * kHashSize);
    w->hashValues = (uint16_t *)malloc(sizeof(uint16_t) * kHashSize);
    w->file = fopen(path, "wb");
    if (!w->ref || !w->indexes || !w->bins || !w->entries || !w->lut || !w->errors || !w->hashKeys
        || !w->hashValues || !w->file) {
        w->failed = 1;
        VGSGifWriterClose(w);
        return NULL;
    }
    setvbuf(w->file, NULL, _IOFBF, 1 << 18);

    gs_write(w, "GIF89a", 6);
    gs_word(w, width);
    gs_word(w, height);
    gs_byte(w, 0x70);           // no global palette, 8 bits per colour
    gs_byte(w, 0);
    gs_byte(w, 0);
    // Loop for ever.
    gs_byte(w, 0x21); gs_byte(w, 0xFF); gs_byte(w, 11);
    gs_write(w, "NETSCAPE2.0", 11);
    gs_byte(w, 3); gs_byte(w, 1); gs_word(w, 0); gs_byte(w, 0);
    return w;
}

int VGSGifWriterAddFrame(VGSGifWriter *w, const uint8_t *bgra, size_t bytesPerRow, int delayCentiseconds) {
    if (!w || w->failed || !bgra) return -1;
    const int W = w->width, H = w->height;
    const int first = (w->frames == 0);
    const int tolerance = w->tolerance;
    uint8_t *mask = w->indexes;
    int minX = W, minY = H, maxX = -1, maxY = -1;

    memset(w->bins, 0, sizeof(VGSBin) * kBins);
    for (int y = 0; y < H; y++) {
        const uint8_t *p = bgra + (size_t)y * bytesPerRow;
        const uint8_t *q = w->ref + (size_t)y * W * 3;
        uint8_t *m = mask + (size_t)y * W;
        int rowMin = W, rowMax = -1;
        for (int x = 0; x < W; x++, p += 4, q += 3) {
            const int b = p[0], g = p[1], r = p[2];
            int changed = 1;
            if (!first) {
                const int dr = r - q[0], dg = g - q[1], db = b - q[2];
                changed = (dr > tolerance || dr < -tolerance || dg > tolerance || dg < -tolerance
                           || db > tolerance || db < -tolerance);
            }
            m[x] = (uint8_t)changed;
            if (changed) {
                VGSBin *bin = &w->bins[gs_bin(r, g, b)];
                bin->count++;
                bin->r += (uint32_t)r;
                bin->g += (uint32_t)g;
                bin->b += (uint32_t)b;
                if (x < rowMin) rowMin = x;
                rowMax = x;
            }
        }
        if (rowMax >= 0) {
            if (rowMin < minX) minX = rowMin;
            if (rowMax > maxX) maxX = rowMax;
            if (y < minY) minY = y;
            maxY = y;
        }
    }
    if (maxX < 0) {
        // Nothing moved: a single see-through pixel carries the time.
        minX = maxX = 0;
        minY = maxY = 0;
    }

    gs_build_palette(w);
    const int transparent = first ? -1 : w->paletteCount;
    const int symbols = w->paletteCount + (first ? 0 : 1);
    int bits = 1;
    while ((1 << bits) < symbols) bits++;
    const int minCodeSize = bits < 2 ? 2 : bits;

    const int boxW = maxX - minX + 1, boxH = maxY - minY + 1;
    uint8_t *out = w->indexes;
    size_t outCount = 0;
    int *errorsNow = w->errors;
    int *errorsNext = w->errors + (size_t)(W + 2) * 3;
    if (w->dither) memset(w->errors, 0, sizeof(int) * (size_t)(W + 2) * 3 * 2);

    for (int y = minY; y <= maxY; y++) {
        const uint8_t *p = bgra + (size_t)y * bytesPerRow + (size_t)minX * 4;
        uint8_t *q = w->ref + ((size_t)y * W + minX) * 3;
        const uint8_t *m = mask + (size_t)y * W + minX;
        for (int x = 0; x < boxW; x++, p += 4, q += 3) {
            // Reading m[x] before writing out[outCount] is safe: outCount never runs ahead of the read position.
            if (!m[x]) {
                out[outCount++] = (uint8_t)transparent;
                continue;
            }
            int b = p[0], g = p[1], r = p[2];
            q[0] = (uint8_t)r; q[1] = (uint8_t)g; q[2] = (uint8_t)b;
            int index;
            if (w->dither) {
                int *e = errorsNow + (x + 1) * 3;
                r = gs_clamp(r + e[0] / 16);
                g = gs_clamp(g + e[1] / 16);
                b = gs_clamp(b + e[2] / 16);
                const int bin = gs_bin(r, g, b);
                index = w->lut[bin];
                if (index < 0) {
                    index = gs_nearest(w, (r & ~7) | 4, (g & ~7) | 4, (b & ~7) | 4);
                    w->lut[bin] = (int16_t)index;
                }
                const uint8_t *c = w->palette + index * 3;
                const int spread[3] = { (r - c[0]) * 3 / 4, (g - c[1]) * 3 / 4, (b - c[2]) * 3 / 4 };
                int *down = errorsNext + (x + 1) * 3;
                for (int k = 0; k < 3; k++) {
                    e[3 + k] += spread[k] * 7;
                    down[k - 3] += spread[k] * 3;
                    down[k] += spread[k] * 5;
                    down[3 + k] += spread[k];
                }
            } else {
                index = w->lut[gs_bin(r, g, b)];
                if (index < 0) index = 0;
            }
            out[outCount++] = (uint8_t)index;
        }
        if (w->dither) {
            int *swap = errorsNow;
            errorsNow = errorsNext;
            errorsNext = swap;
            memset(errorsNext, 0, sizeof(int) * (size_t)(W + 2) * 3);
        }
    }

    if (delayCentiseconds < 2) delayCentiseconds = 2;       // players treat less as "slow"
    if (delayCentiseconds > 65535) delayCentiseconds = 65535;
    gs_byte(w, 0x21); gs_byte(w, 0xF9); gs_byte(w, 4);
    gs_byte(w, 0x04 | (first ? 0 : 1));                     // keep what is drawn; see-through colour if any
    gs_word(w, delayCentiseconds);
    gs_byte(w, first ? 0 : transparent);
    gs_byte(w, 0);

    gs_byte(w, 0x2C);
    gs_word(w, minX); gs_word(w, minY); gs_word(w, boxW); gs_word(w, boxH);
    gs_byte(w, 0x80 | (bits - 1));
    gs_write(w, w->palette, (size_t)(1 << bits) * 3);
    gs_lzw(w, out, outCount, minCodeSize);

    w->frames++;
    return w->failed ? -1 : 0;
}

int VGSGifWriterClose(VGSGifWriter *w) {
    if (!w) return -1;
    int result = w->failed ? -1 : 0;
    if (w->file) {
        if (!w->failed) gs_byte(w, 0x3B);
        if (fflush(w->file) != 0 || ferror(w->file)) result = -1;
        if (fclose(w->file) != 0) result = -1;
        if (w->failed) result = -1;
    }
    free(w->ref);
    free(w->indexes);
    free(w->bins);
    free(w->entries);
    free(w->lut);
    free(w->errors);
    free(w->hashKeys);
    free(w->hashValues);
    free(w);
    return result;
}

long long VGSGifWriterBytesWritten(const VGSGifWriter *w) {
    return w ? w->bytes : 0;
}
