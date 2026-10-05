// facebench: a host-side stand-in for Arduino_GFX, just enough for AgentTouch's
// face.cpp / grokface.cpp to compile and draw into a 480x480 RGB565 buffer.
//
// The raster algorithms (fillRoundRect / fill & draw ellipse helpers / fillArc /
// fillTriangle / Bresenham line / classic 5x8 glyphs) are transcribed from
// Arduino_GFX (github.com/moononournation/Arduino_GFX, src/Arduino_GFX.cpp),
// which is BSD-licensed (Copyright (c) 2012 Adafruit Industries; see
// license.txt in that repository). They must stay pixel-identical to the
// library — the whole point of this file is to reproduce the board's pixels.
#pragma once
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <float.h>
#include <algorithm>

using std::min;
using std::max;

uint32_t millis();
void delay(uint32_t ms);

struct GFXfont;   // never dereferenced: text in custom fonts is not rendered

class Arduino_Canvas {
 public:
  static const int W = 480, H = 480;
  uint16_t fb[W * H];

  Arduino_Canvas() { memset(fb, 0, sizeof(fb)); }

  // ---- pixel sinks (Arduino_Canvas: clip, no rotation in the bench)
  void writePixel(int16_t x, int16_t y, uint16_t c) {
    if (x >= 0 && x < W && y >= 0 && y < H) fb[y * W + x] = c;
  }
  void writeFastHLine(int16_t x, int16_t y, int16_t w, uint16_t c) {
    if (y < 0 || y >= H || !w) return;
    if (w < 0) { x += w + 1; w = -w; }
    int x2 = x + w - 1;
    if (x2 < 0 || x >= W) return;
    if (x < 0) x = 0;
    if (x2 >= W) x2 = W - 1;
    for (int i = x; i <= x2; i++) fb[y * W + i] = c;
  }
  void writeFastVLine(int16_t x, int16_t y, int16_t h, uint16_t c) {
    if (x < 0 || x >= W || !h) return;
    if (h < 0) { y += h + 1; h = -h; }
    int y2 = y + h - 1;
    if (y2 < 0 || y >= H) return;
    if (y < 0) y = 0;
    if (y2 >= H) y2 = H - 1;
    for (int j = y; j <= y2; j++) fb[j * W + x] = c;
  }
  void writeFillRect(int16_t x, int16_t y, int16_t w, int16_t h, uint16_t c) {
    if (!w || !h) return;
    if (w < 0) { x += w + 1; w = -w; }
    if (h < 0) { y += h + 1; h = -h; }
    for (int j = 0; j < h; j++) writeFastHLine(x, y + j, w, c);
  }

  // ---- public API used by face.cpp / grokface.cpp
  void fillScreen(uint16_t c) { for (int i = 0; i < W * H; i++) fb[i] = c; }
  void fillRect(int16_t x, int16_t y, int16_t w, int16_t h, uint16_t c) { writeFillRect(x, y, w, h, c); }
  void drawFastHLine(int16_t x, int16_t y, int16_t w, uint16_t c) { writeFastHLine(x, y, w, c); }
  void drawFastVLine(int16_t x, int16_t y, int16_t h, uint16_t c) { writeFastVLine(x, y, h, c); }
  void drawLine(int16_t x0, int16_t y0, int16_t x1, int16_t y1, uint16_t c);
  void drawCircle(int16_t x, int16_t y, int16_t r, uint16_t c) { ellipseHelper(x, y, r, r, 0xf, c); }
  void fillCircle(int16_t x, int16_t y, int16_t r, uint16_t c) { fillEllipseHelper(x, y, r, r, 3, 0, c); }
  void drawRoundRect(int16_t x, int16_t y, int16_t w, int16_t h, int16_t r, uint16_t c);
  void fillRoundRect(int16_t x, int16_t y, int16_t w, int16_t h, int16_t r, uint16_t c);
  void fillTriangle(int16_t x0, int16_t y0, int16_t x1, int16_t y1, int16_t x2, int16_t y2, uint16_t c);
  void fillArc(int16_t x, int16_t y, int16_t r1, int16_t r2, float start, float end, uint16_t c);

  // classic 5x8 font only (setFont(nullptr)); custom fonts draw nothing
  void setTextSize(uint8_t s) { ts = s ? s : 1; }
  void setTextColor(uint16_t c) { tc = c; }
  void setCursor(int16_t x, int16_t y) { cx = x; cy = y; }
  int16_t getCursorX() const { return cx; }
  void setFont(const GFXfont* f) { custom = f != nullptr; }
  void setFont(const uint8_t* f) { custom = f != nullptr; }
  size_t write(uint8_t ch);
  size_t print(const char* s) { size_t n = 0; while (*s) n += write((uint8_t)*s++); return n; }
  void flush() {}
  void setRotation(uint8_t) {}

 private:
  void ellipseHelper(int32_t x, int32_t y, int32_t rx, int32_t ry, uint8_t corner, uint16_t c);
  void fillEllipseHelper(int32_t x, int32_t y, int32_t rx, int32_t ry, uint8_t corners, int16_t delta, uint16_t c);
  void fillArcHelper(int16_t cx, int16_t cy, int16_t orad, int16_t irad, float start, float end, uint16_t c);
  void drawChar(int16_t x, int16_t y, unsigned char ch, uint16_t c);
  uint8_t ts = 1;
  uint16_t tc = 0xFFFF;
  int16_t cx = 0, cy = 0;
  bool custom = false;
};
