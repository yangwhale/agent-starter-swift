// facebench: compiles AgentTouch's face.cpp in this TU so the bench can read
// its file-static engine state (blink amount, expression pool) per frame.
#include "face.cpp"
float bench_blinkK() { return s_blinkK; }
int bench_variant(float* v) {
  v[0] = s_vDisp.wL; v[1] = s_vDisp.hL; v[2] = s_vDisp.wR; v[3] = s_vDisp.hR;
  v[4] = s_vDisp.dy; v[5] = s_vDisp.aux; v[6] = s_vDisp.pill;
  return s_vIdx;
}
