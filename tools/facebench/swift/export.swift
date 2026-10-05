// facebench: dump CCFaceMotion's per-frame draw list as JSON lines, so a
// renderer that mirrors CCFacePainter can rasterise the port off-device.
//
//   export <skin> <look> <t0_s> <dur_s> <fps> <seed>  > frames.jsonl
//
// look = CCFaceLook raw name (idle working needs done off listening offline
// surprised petting bored). t is absolute (same zero as the reference bench's
// millis()/1000) so every sin()/modulo phase lines up with the board.
import Foundation

let a = CommandLine.arguments
// "spring <fps>": the port's morph progress sampled k frames after a switch
if a.count >= 3 && a[1] == "spring", let fps = Double(a[2]) {
    print((0..<16).map { String(format: "%.4f", CCFaceMotion.spring(Double($0) / fps)) }.joined(separator: " "))
    exit(0)
}
guard a.count >= 7, let skin = CCFaceSkin(rawValue: a[1]),
      let t0 = Double(a[3]), let dur = Double(a[4]), let fps = Double(a[5]), let seed = UInt64(a[6])
else { FileHandle.standardError.write("usage: export skin look t0 dur fps seed\n".data(using: .utf8)!); exit(2) }
let looks: [String: CCFaceLook] = ["off": .off, "idle": .idle, "working": .working, "needs": .needs,
                                   "done": .done, "listening": .listening, "bored": .bored,
                                   "surprised": .surprised, "petting": .petting, "offline": .offline]
// "tour:<seg_s>:a,b,c" — states back to back, carried over the way CCFaceClock does it
// (since = the moment of the change; grok morphs from whatever was showing then)
var tour: [CCFaceLook] = []
var seg = 0.0
if a[2].hasPrefix("tour:") {
    let parts = a[2].split(separator: ":")
    seg = Double(parts[1])!
    tour = parts[2].split(separator: ",").map { looks[String($0)]! }
}
// "idle@-640": entered that many seconds before t0 (to reach the 10-minute "bored" sighs)
var sinceOffset = 0.0
var lookName = a[2]
if !a[2].hasPrefix("tour:"), let at = a[2].firstIndex(of: "@") {
    sinceOffset = Double(a[2][a[2].index(after: at)...])!
    lookName = String(a[2][..<at])
}
guard let look = tour.first ?? looks[lookName] else { exit(2) }
let compact = a.count > 7 && a[7] == "compact"
// "stats": engine timeline only (blink amount, pool variant, grok target + spring), no draw list
if a.count > 7 && a[7] == "stats" {
    let n = Int((dur * fps).rounded(.down))
    var out = ""
    for i in 0..<n {
        let t = t0 + Double(i) / fps
        let pill = skin != .grok
        let b = CCFaceMotion.blink(look: look, pill: pill, since: t0, t: t, seed: seed)
        let v = CCFaceMotion.variant(look: look, since: t0, t: t, seed: seed)
        let g = CCFaceMotion.grokExpression(look: look, since: t0, t: t, seed: seed, enteredFrom: nil)
        let sp = g.from == nil ? 1 : CCFaceMotion.spring(t - g.at)
        out += String(format: "%.4f %d %d %.4f %.2f %.2f\n", b, v.index, g.to, sp, v.disp.hL, v.disp.hR)
        if out.utf8.count > 1 << 20 { FileHandle.standardOutput.write(out.data(using: .utf8)!); out = "" }
    }
    FileHandle.standardOutput.write(out.data(using: .utf8)!)
    exit(0)
}

func tone(_ t: CCFaceTone) -> String { "\(t)" }
func ink(_ k: CCFaceInk) -> String {
    "\"\(tone(k.tone))\",\(k.level),\(CCFaceMask.alpha(k)),\(CCFaceMask.replaces(k))"
}
func f(_ x: Double) -> String { String(format: "%.4f", x) }

let n = Int((dur * fps).rounded(.down))
var out = ""
var tourK = -1, tourSince = t0
var tourFrom: Int? = nil
for i in 0..<n {
    let t = t0 + Double(i) / fps
    var lk = look, since = t0 + sinceOffset
    if !tour.isEmpty {
        let k = min(Int((t - t0) / seg), tour.count - 1)
        lk = tour[k]; since = t0 + Double(k) * seg
        if k != tourK {
            if tourK >= 0, skin == .grok {
                let prev = tour[tourK]
                let r = CCFaceMotion.resolve(look: prev, since: tourSince, t: since, seed: seed, grokFrom: tourFrom)
                tourFrom = CCFaceMotion.grokExpression(look: r.look, since: r.since, t: since, seed: seed,
                                                       enteredFrom: r.grokFrom).to
            }
            tourK = k; tourSince = since
        }
    }
    let s = CCFaceMotion.scene(look: lk, .init(mood: .idle, skin: skin, t: t, since: since, seed: seed,
                                                compact: compact, grokFrom: tour.isEmpty ? nil : tourFrom))
    var ps: [String] = []
    for p in s.prims {
        switch p {
        case let .roundRect(x, y, w, h, r, k): ps.append("[\"rr\",\(f(x)),\(f(y)),\(f(w)),\(f(h)),\(f(r)),\(ink(k))]")
        case let .rect(x, y, w, h, k): ps.append("[\"rect\",\(f(x)),\(f(y)),\(f(w)),\(f(h)),\(ink(k))]")
        case let .triangle(p0, p1, p2, k): ps.append("[\"tri\",\(f(p0.x)),\(f(p0.y)),\(f(p1.x)),\(f(p1.y)),\(f(p2.x)),\(f(p2.y)),\(ink(k))]")
        case let .circle(cx, cy, r, k): ps.append("[\"circle\",\(f(cx)),\(f(cy)),\(f(r)),\(ink(k))]")
        case let .arc(cx, cy, r1, r2, from, to, k): ps.append("[\"arc\",\(f(cx)),\(f(cy)),\(f(r1)),\(f(r2)),\(f(from)),\(f(to)),\(ink(k))]")
        case let .pill(cx, cy, len, th, deg, k): ps.append("[\"pill\",\(f(cx)),\(f(cy)),\(f(len)),\(f(th)),\(f(deg)),\(ink(k))]")
        case let .line(p0, p1, k): ps.append("[\"line\",\(f(p0.x)),\(f(p0.y)),\(f(p1.x)),\(f(p1.y)),\(ink(k))]")
        case let .polygon(pts, k):
            ps.append("[\"poly\",[" + pts.map { "\(f($0.x)),\(f($0.y))" }.joined(separator: ",") + "],\(ink(k))]")
        }
    }
    let g = s.grokExpr.map(String.init) ?? "null"
    out += "{\"i\":\(i),\"look\":\"\(s.look)\",\"blink\":\(f(s.blink)),\"lid\":\(f(s.lidOpen)),\"gx\":\(f(s.gazeX)),\"gy\":\(f(s.gazeY)),"
        + "\"bob\":\(f(s.bob)),\"grok\":\(g),\"prims\":[" + ps.joined(separator: ",") + "]}\n"
    if out.utf8.count > 1 << 20 { FileHandle.standardOutput.write(out.data(using: .utf8)!); out = "" }
}
FileHandle.standardOutput.write(out.data(using: .utf8)!)
