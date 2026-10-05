// facebench stub: the face only uses the anti-aliased CJK text helpers for the
// bubbles / cards, which are not part of the comparison. Draw nothing.
#pragma once
#include <Arduino_GFX_Library.h>
inline int almanacTextWidth(const char*) { return 0; }
inline int almanacTextWidthSmall(const char*) { return 0; }
inline int almanacTextWidthSmallTrack(const char*, int) { return 0; }
inline void almanacPrint(Arduino_Canvas*, int, int, const char*, uint16_t, uint16_t) {}
inline void almanacPrintSmall(Arduino_Canvas*, int, int, const char*, uint16_t, uint16_t) {}
inline void almanacPrintSmallTrack(Arduino_Canvas*, int, int, const char*, uint16_t, int) {}
