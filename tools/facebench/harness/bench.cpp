// facebench: render AgentTouch's face (the real face.cpp + grokface.cpp, built
// against a fake Arduino_GFX) for one skin x one face state over a time span,
// at a fixed frame rate, with a controllable millis().
//
//   bench <skin 0-5> <state> <t0_ms> <dur_ms> <fps> <frames.raw|-> <params.jsonl>
//
// state: idle working needs done off listening offline surprised petting bored
// frames.raw = N x 480x480 RGB565 little-endian; params.jsonl = one line per
// frame with the engines' internal state (blink, pool variant, grok morph).
#include "face.h"
#include "grokface.h"
#include <string>
#include <vector>
#include <algorithm>

static uint32_t g_ms = 0;
uint32_t millis() { return g_ms; }
void delay(uint32_t ms) { g_ms += ms; }

float bench_blinkK();
int bench_variant(float* v);
int bench_grokCur();
float bench_grokPos();

static Arduino_Canvas canvas;

static FaceFrame frameFor(const std::string& s) {
  FaceFrame f = {};
  f.agentIdx = 0;
  f.st = ST_IDLE;
  f.battPct = -1;
  f.hideBubble = true;    // the approve bubble belongs to the board, not the face
  // agentStates stay all ST_OFF: they only feed the toast/dots, never the eyes,
  // and keeping them constant keeps the bottom toast from resurfacing
  if (s == "idle") f.st = ST_IDLE;
  else if (s == "working") f.st = ST_WORKING;
  else if (s == "needs") f.st = ST_NEEDS_YOU;
  else if (s == "done") f.st = ST_DONE;
  else if (s == "off") f.st = ST_OFF;
  else if (s == "listening") f.listening = true;
  else if (s == "offline") f.offline = true;
  else if (s == "surprised") f.surprised = true;
  else if (s == "petting") f.petting = true;
  else if (s == "bored") f.bored = true;
  else { fprintf(stderr, "unknown state %s\n", s.c_str()); exit(2); }
  return f;
}

int main(int argc, char** argv) {
  if (argc < 8) { fprintf(stderr, "usage: bench skin state t0 dur fps out.raw out.jsonl\n"); return 2; }
  int skin = atoi(argv[1]);
  std::string st = argv[2];
  uint32_t t0 = strtoul(argv[3], 0, 10), dur = strtoul(argv[4], 0, 10);
  int fps = atoi(argv[5]);
  bool frames = strcmp(argv[6], "-") != 0;   // "-" = engine params only (long runs)
  FILE* fr = frames ? fopen(argv[6], "wb") : nullptr;
  FILE* fp = fopen(argv[7], "w");
  if ((frames && !fr) || !fp) return 3;

  // Warm-up frame 3.5 s earlier in a different skin and state: it burns the
  // bottom toast's 3 s life (it resurfaces on the very first frame), then the
  // skin change resets grok's morph engine and the variant pool so the real
  // run starts cold, exactly like entering the state fresh.
  {
    std::string first = st.rfind("tour:", 0) == 0 ? st.substr(st.rfind(':') + 1, st.find(',') - st.rfind(':') - 1)
                      : st.rfind("seq:", 0) == 0 ? st.substr(4, st.find('@') - 4) : st;
    FaceFrame w = frameFor(first == "off" ? "idle" : "off");
    if (first == "offline") { w = frameFor("offline"); w.listening = true; }
    g_ms = t0 - 3500;
    faceSetSkin((skin + 1) % N_SKINS);
    faceRender(&canvas, w, g_ms);
  }
  faceSetSkin(skin);
  // "tour:<seg_ms>:a,b,c" = walk through states back to back (each a real state
  // change for the engines: blink re-arms, pool restarts on V0, grok morphs over)
  std::vector<std::string> tour;
  uint32_t seg = 0;
  if (st.rfind("tour:", 0) == 0) {
    size_t c = st.find(':', 5);
    seg = strtoul(st.substr(5, c - 5).c_str(), 0, 10);
    std::string rest = st.substr(c + 1);
    for (size_t p = 0; p != std::string::npos;) {
      size_t q = rest.find(',', p);
      tour.push_back(rest.substr(p, q == std::string::npos ? q : q - p));
      p = q == std::string::npos ? q : q + 1;
    }
  }
  // "seq:a@0,b@3200,c@7700" = same, with explicit start offsets (ms from t0)
  std::vector<uint32_t> at;
  if (st.rfind("seq:", 0) == 0) {
    std::string rest = st.substr(4);
    for (size_t p = 0; p != std::string::npos;) {
      size_t q = rest.find(',', p);
      std::string e = rest.substr(p, q == std::string::npos ? q : q - p);
      size_t a = e.find('@');
      tour.push_back(e.substr(0, a));
      at.push_back(strtoul(e.substr(a + 1).c_str(), 0, 10));
      p = q == std::string::npos ? q : q + 1;
    }
  }
  FaceFrame f = frameFor(tour.empty() ? st : tour[0]);
  int n = (int)((uint64_t)dur * fps / 1000);
  for (int i = 0; i < n; i++) {
    uint32_t t = t0 + (uint32_t)((uint64_t)i * 1000 / fps);
    g_ms = t;
    if (!at.empty()) {
      size_t k = 0;
      while (k + 1 < at.size() && t - t0 >= at[k + 1]) k++;
      f = frameFor(tour[k]);
    } else if (!tour.empty()) f = frameFor(tour[std::min<size_t>((t - t0) / seg, tour.size() - 1)]);
    faceRender(&canvas, f, t);
    if (frames) fwrite(canvas.fb, 2, 480 * 480, fr);
    float v[7];
    int vi = bench_variant(v);
    fprintf(fp, "{\"i\":%d,\"t\":%u,\"blink\":%.5f,\"var\":%d,\"vdisp\":[%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f],"
                "\"grokCur\":%d,\"grokPos\":%.5f}\n",
            i, t - t0, bench_blinkK(), vi, v[0], v[1], v[2], v[3], v[4], v[5], v[6],
            bench_grokCur(), bench_grokPos());
  }
  if (fr) fclose(fr);
  fclose(fp);
  return 0;
}
