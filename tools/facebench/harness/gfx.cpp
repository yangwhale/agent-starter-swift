// facebench: raster algorithms for the fake Arduino_Canvas.
// Transcribed from Arduino_GFX src/Arduino_GFX.cpp (BSD, Copyright (c) 2012
// Adafruit Industries) — keep them literal; see Arduino_GFX_Library.h.
#include "Arduino_GFX_Library.h"

#define DEGTORAD 0.017453292519943295769236907684886F
#define _swap_int16_t(a, b) { int16_t t = a; a = b; b = t; }
#define _diff(a, b) ((a > b) ? (a - b) : (b - a))

void Arduino_Canvas::drawLine(int16_t x0, int16_t y0, int16_t x1, int16_t y1, uint16_t color) {
  if (x0 == x1) {
    if (y0 > y1) _swap_int16_t(y0, y1);
    writeFastVLine(x0, y0, y1 - y0 + 1, color);
  } else if (y0 == y1) {
    if (x0 > x1) _swap_int16_t(x0, x1);
    writeFastHLine(x0, y0, x1 - x0 + 1, color);
  } else {  // writeSlashLine (Bresenham)
    bool steep = _diff(y1, y0) > _diff(x1, x0);
    if (steep) { _swap_int16_t(x0, y0); _swap_int16_t(x1, y1); }
    if (x0 > x1) { _swap_int16_t(x0, x1); _swap_int16_t(y0, y1); }
    int16_t dx = x1 - x0, dy = _diff(y1, y0), err = dx >> 1;
    int16_t step = (y0 < y1) ? 1 : -1;
    for (; x0 <= x1; x0++) {
      if (steep) writePixel(y0, x0, color); else writePixel(x0, y0, color);
      err -= dy;
      if (err < 0) { err += dx; y0 += step; }
    }
  }
}

void Arduino_Canvas::ellipseHelper(int32_t x, int32_t y, int32_t rx, int32_t ry,
                                   uint8_t cornername, uint16_t color) {
  if (rx < 0 || ry < 0 || ((rx == 0) && (ry == 0))) return;
  if (ry == 0) { writeFastHLine(x - rx, y, (ry << 2) + 1, color); return; }
  if (rx == 0) { writeFastVLine(x, y - ry, (rx << 2) + 1, color); return; }
  int32_t xt, yt, s, i;
  int32_t rx2 = rx * rx, ry2 = ry * ry;
  i = -1; xt = 0; yt = ry;
  s = (ry2 << 1) + rx2 * (1 - (ry << 1));
  do {
    while (s < 0) s += ry2 * ((++xt << 2) + 2);
    if (cornername & 0x1) writeFastHLine(x - xt, y - yt, xt - i, color);
    if (cornername & 0x2) writeFastHLine(x + i + 1, y - yt, xt - i, color);
    if (cornername & 0x4) writeFastHLine(x + i + 1, y + yt, xt - i, color);
    if (cornername & 0x8) writeFastHLine(x - xt, y + yt, xt - i, color);
    i = xt;
    s -= (--yt) * rx2 << 2;
  } while (ry2 * xt <= rx2 * yt);
  i = -1; yt = 0; xt = rx;
  s = (rx2 << 1) + ry2 * (1 - (rx << 1));
  do {
    while (s < 0) s += rx2 * ((++yt << 2) + 2);
    if (cornername & 0x1) writeFastVLine(x - xt, y - yt, yt - i, color);
    if (cornername & 0x2) writeFastVLine(x + xt, y - yt, yt - i, color);
    if (cornername & 0x4) writeFastVLine(x + xt, y + i + 1, yt - i, color);
    if (cornername & 0x8) writeFastVLine(x - xt, y + i + 1, yt - i, color);
    i = yt;
    s -= (--xt) * ry2 << 2;
  } while (rx2 * yt <= ry2 * xt);
}

void Arduino_Canvas::fillEllipseHelper(int32_t x, int32_t y, int32_t rx, int32_t ry,
                                       uint8_t corners, int16_t delta, uint16_t color) {
  if (rx < 0 || ry < 0 || ((rx == 0) && (ry == 0))) return;
  if (ry == 0) { writeFastHLine(x - rx, y, (ry << 2) + 1, color); return; }
  if (rx == 0) { writeFastVLine(x, y - ry, (rx << 2) + 1, color); return; }
  int32_t xt, yt, i;
  int32_t rx2 = (int32_t)rx * rx, ry2 = (int32_t)ry * ry;
  int32_t s;
  writeFastHLine(x - rx, y, (rx << 1) + 1, color);
  i = 0; yt = 0; xt = rx;
  s = (rx2 << 1) + ry2 * (1 - (rx << 1));
  do {
    while (s < 0) s += rx2 * ((++yt << 2) + 2);
    if (corners & 1) writeFillRect(x - xt, y - yt, (xt << 1) + 1 + delta, yt - i, color);
    if (corners & 2) writeFillRect(x - xt, y + i + 1, (xt << 1) + 1 + delta, yt - i, color);
    i = yt;
    s -= (--xt) * ry2 << 2;
  } while (rx2 * yt <= ry2 * xt);
  xt = 0; yt = ry;
  s = (ry2 << 1) + rx2 * (1 - (ry << 1));
  do {
    while (s < 0) s += ry2 * ((++xt << 2) + 2);
    if (corners & 1) writeFastHLine(x - xt, y - yt, (xt << 1) + 1 + delta, color);
    if (corners & 2) writeFastHLine(x - xt, y + yt, (xt << 1) + 1 + delta, color);
    s -= (--yt) * rx2 << 2;
  } while (ry2 * xt <= rx2 * yt);
}

void Arduino_Canvas::drawRoundRect(int16_t x, int16_t y, int16_t w, int16_t h, int16_t r, uint16_t color) {
  int16_t max_radius = ((w < h) ? w : h) / 2;
  if (r > max_radius) r = max_radius;
  writeFastHLine(x + r, y, w - 2 * r, color);
  writeFastHLine(x + r, y + h - 1, w - 2 * r, color);
  writeFastVLine(x, y + r, h - 2 * r, color);
  writeFastVLine(x + w - 1, y + r, h - 2 * r, color);
  ellipseHelper(x + r, y + r, r, r, 1, color);
  ellipseHelper(x + w - r - 1, y + r, r, r, 2, color);
  ellipseHelper(x + w - r - 1, y + h - r - 1, r, r, 4, color);
  ellipseHelper(x + r, y + h - r - 1, r, r, 8, color);
}

void Arduino_Canvas::fillRoundRect(int16_t x, int16_t y, int16_t w, int16_t h, int16_t r, uint16_t color) {
  int16_t max_radius = ((w < h) ? w : h) / 2;
  if (r > max_radius) r = max_radius;
  writeFillRect(x, y + r, w, h - (r << 1), color);
  fillEllipseHelper(x + r, y + r, r, r, 1, w - 2 * r - 1, color);
  fillEllipseHelper(x + r, y + h - r - 1, r, r, 2, w - 2 * r - 1, color);
}

void Arduino_Canvas::fillTriangle(int16_t x0, int16_t y0, int16_t x1, int16_t y1,
                                  int16_t x2, int16_t y2, uint16_t color) {
  int16_t a, b, y, last;
  if (y0 > y1) { _swap_int16_t(y0, y1); _swap_int16_t(x0, x1); }
  if (y1 > y2) { _swap_int16_t(y2, y1); _swap_int16_t(x2, x1); }
  if (y0 > y1) { _swap_int16_t(y0, y1); _swap_int16_t(x0, x1); }
  if (y0 == y2) {
    a = b = x0;
    if (x1 < a) a = x1; else if (x1 > b) b = x1;
    if (x2 < a) a = x2; else if (x2 > b) b = x2;
    writeFastHLine(a, y0, b - a + 1, color);
    return;
  }
  int16_t dx01 = x1 - x0, dy01 = y1 - y0, dx02 = x2 - x0, dy02 = y2 - y0,
          dx12 = x2 - x1, dy12 = y2 - y1;
  int32_t sa = 0, sb = 0;
  last = (y1 == y2) ? y1 : y1 - 1;
  for (y = y0; y <= last; y++) {
    a = x0 + sa / dy01;
    b = x0 + sb / dy02;
    sa += dx01; sb += dx02;
    if (a > b) _swap_int16_t(a, b);
    writeFastHLine(a, y, b - a + 1, color);
  }
  sa = (int32_t)dx12 * (y - y1);
  sb = (int32_t)dx02 * (y - y0);
  for (; y <= y2; y++) {
    a = x1 + sa / dy12;
    b = x0 + sb / dy02;
    sa += dx12; sb += dx02;
    if (a > b) _swap_int16_t(a, b);
    writeFastHLine(a, y, b - a + 1, color);
  }
}

void Arduino_Canvas::fillArc(int16_t x, int16_t y, int16_t r1, int16_t r2, float start, float end, uint16_t color) {
  if (r1 < r2) _swap_int16_t(r1, r2);
  if (r1 < 1) r1 = 1;
  if (r2 < 1) r2 = 1;
  bool equal = fabsf(start - end) < FLT_EPSILON;
  start = fmodf(start, 360);
  end = fmodf(end, 360);
  if (start < 0) start += 360.0;
  if (end < 0) end += 360.0;
  if (!equal && (fabsf(start - end) <= 0.0001)) { start = .0; end = 360.0; }
  fillArcHelper(x, y, r1, r2, start, end, color);
}

void Arduino_Canvas::fillArcHelper(int16_t cx, int16_t cy, int16_t oradius, int16_t iradius,
                                   float start, float end, uint16_t color) {
  if ((start == 90.0) || (start == 180.0) || (start == 270.0) || (start == 360.0)) start -= 0.1;
  if ((end == 90.0) || (end == 180.0) || (end == 270.0) || (end == 360.0)) end -= 0.1;
  float s_cos = (cos(start * DEGTORAD));
  float e_cos = (cos(end * DEGTORAD));
  float sslope = s_cos / (sin(start * DEGTORAD));
  float eslope = e_cos / (sin(end * DEGTORAD));
  float swidth = 0.5 / s_cos;
  float ewidth = -0.5 / e_cos;
  --iradius;
  int32_t ir2 = iradius * iradius + iradius;
  int32_t or2 = oradius * oradius + oradius;
  bool start180 = !(start < 180.0);
  bool end180 = end < 180.0;
  bool reversed = start + 180.0 < end || (end < start && start < end + 180.0);
  int32_t xs = -oradius, y = -oradius, ye = oradius, xe = oradius + 1;
  if (!reversed) {
    if ((end >= 270 || end < 90) && (start >= 270 || start < 90)) xs = 0;
    else if (end < 270 && end >= 90 && start < 270 && start >= 90) xe = 1;
    if (end >= 180 && start >= 180) ye = 0;
    else if (end < 180 && start < 180) y = 0;
  }
  do {
    int32_t y2 = y * y;
    int32_t x = xs;
    if (x < 0) {
      while (x * x + y2 >= or2) ++x;
      if (xe != 1) xe = 1 - x;
    }
    float ysslope = (y + swidth) * sslope;
    float yeslope = (y + ewidth) * eslope;
    int32_t len = 0;
    do {
      bool flg1 = start180 != (x <= ysslope);
      bool flg2 = end180 != (x <= yeslope);
      int32_t distance = x * x + y2;
      if (distance >= ir2 && ((flg1 && flg2) || (reversed && (flg1 || flg2))) && x != xe && distance < or2) {
        ++len;
      } else {
        if (len) { writeFastHLine(cx + x - len, cy + y, len, color); len = 0; }
        if (distance >= or2) break;
        if (x < 0 && distance < ir2) x = -x;
      }
    } while (++x <= xe);
  } while (++y <= ye);
}

// Classic 5x8 glyphs (glcdfont.h, column-major, bit 0 = top row). Only the
// characters the face prints in the default font are carried.
static const unsigned char* glyph(unsigned char c) {
  static const unsigned char Q[5] = {0x02, 0x01, 0x59, 0x09, 0x06};   // '?'
  static const unsigned char Z[5] = {0x44, 0x64, 0x54, 0x4C, 0x44};   // 'z'
  static const unsigned char D[5] = {0x00, 0x00, 0x60, 0x60, 0x00};   // '.'
  static const unsigned char N[5] = {0, 0, 0, 0, 0};
  return c == '?' ? Q : c == 'z' ? Z : c == '.' ? D : N;
}

void Arduino_Canvas::drawChar(int16_t x, int16_t y, unsigned char ch, uint16_t color) {
  const unsigned char* g = glyph(ch);
  for (int i = 0; i < 5; i++) {
    uint8_t line = g[i];
    for (int j = 0; j < 8; j++, line >>= 1)
      if (line & 1) writeFillRect(x + i * ts, y + j * ts, ts, ts, color);
  }
}

size_t Arduino_Canvas::write(uint8_t ch) {
  if (custom) { cx += 10; return 1; }   // custom-font text is not part of the comparison
  if (ch == '\n') { cx = 0; cy += 8 * ts; return 1; }
  if (ch == '\r') return 1;
  drawChar(cx, cy, ch, tc);
  cx += 6 * ts;
  return 1;
}
