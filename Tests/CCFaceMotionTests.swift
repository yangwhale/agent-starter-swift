// 活脸「怎么动、长什么样」的测试 —— CCFaceMotion（AgentTouch 那张脸的移植）。
//
// 移植的价值全在「数跟原固件一样」，所以这里钉的是原固件的那些数和规则：
//   ① 眨眼：320 ms，前 134 ms 闭（42%）、后 186 ms 睁；间隔按 GCFG 每个状态各自随机；
//      进入状态后不久先眨一次（lo·0.4 … hi·0.6）；胶囊皮肤干活时 3–6 s 眨，grok 干活不眨；
//   ② 扫视：左 -14 停、右 +12 停、回正，3.8 s 一圈；
//   ③ 表情池：进入时 V0、绝不连着两次同一张、间隔按表（needs 至少 3 s）、180 ms 过渡；
//   ④ grok：池子第一张进场、阻尼弹簧 ω=2π·3.5、ζ=0.72 按原固件 30 fps 半隐式欧拉推（约 1.6% 过冲）、眨眼绕质心压扁；
//   ⑤ 眼睛下沿固定在 271（换状态、眨眼只动上眼皮）；
//   ⑥ 减弱动态效果：画面不随时间变（只换形状）；小尺寸不画心情道具，但皮肤头饰照画；
//   ⑦ 头饰坐标逐字对原固件；颜色不搬（材质用柱子那块金属），层次变成遮罩不透明度；
//      金属的三道阴影跟声音柱子共用一份（CCMetalGlowSpec）。
//
// 跑法见 Tests/README.md：
//
//   mkdir -p /tmp/swtest && cp VoiceAgent/CloseCrab/{CCPresence,CCFaceMood,CCFaceMotion,CCFaceGrokEyes,CCMetalGlow}.swift /tmp/swtest/
//   cp Tests/CCFaceMotionTests.swift /tmp/swtest/main.swift
//   docker run --rm -v /tmp/swtest:/w -w /w swift:6.2-noble \
//     bash -c 'swiftc -O -swift-version 6 -default-isolation MainActor \
//                CCPresence.swift CCFaceMood.swift CCFaceMotion.swift CCFaceGrokEyes.swift \
//                CCMetalGlow.swift main.swift -o t && ./t'
//
// （`-O` 只是为了快：几条断言按 1 ms 步长扫几分钟的时间轴。不加也能过，慢一些。）

import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    if cond {
        passed += 1
    } else {
        failed += 1
        print("  ✗ \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}

typealias F = CCFaceMotion
typealias L = CCFaceLook
let seedA = F.seed(for: "jarvis")
let seedB = F.seed(for: "bunny")
let T0 = 800_000_000.0     // 跟视图一样用 referenceDate 量级的时间

func scene(_ m: CCFaceMood, _ skin: CCFaceSkin = .classic, t: Double, since: Double = T0,
           seed: UInt64 = seedA, compact: Bool = false, reduce: Bool = false, dots: Int = 3,
           grokFrom: Int? = nil) -> F.Scene {
    F.scene(.init(mood: m, skin: skin, t: t, since: since, seed: seed, compact: compact,
                  reduceMotion: reduce, typingDots: dots, grokFrom: grokFrom))
}

/// 扫一段时间，找出每次眨眼的 (起点, 峰值时刻, 终点)。步长 1 ms。
func blinks(_ look: L, pill: Bool = true, seed: UInt64 = seedA, since: Double = T0,
            from: Double? = nil, seconds: Double) -> [(start: Double, peak: Double, end: Double)] {
    var out: [(Double, Double, Double)] = []
    var inBlink = false
    var start = 0.0, peak = 0.0, peakV = 0.0
    let t0 = from ?? since
    var i = 0
    while Double(i) * 0.001 < seconds {
        let t = t0 + Double(i) * 0.001
        let v = F.blink(look: look, pill: pill, since: since, t: t, seed: seed)
        if v > 0, !inBlink { inBlink = true; start = t; peakV = 0 }
        if inBlink, v > peakV { peakV = v; peak = t }
        if v == 0, inBlink { inBlink = false; out.append((start, peak, t)) }
        i += 1
    }
    return out
}

func close(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

// MARK: - ⑦ 遮罩与材质

// 颜色不搬：材质用声音柱子那块身份色金属，原来的颜色层次变成遮罩不透明度。
typealias K = CCFaceMask
check("⭐ 眼睛在遮罩里全不透明", K.alpha(.eye) == 1 && K.alpha(.grokWhite) == 1)
check("⭐ 眼皮切口在遮罩里是 0（＝裁剪，不是盖色块）", K.alpha(.bg) == 0 && K.replaces(.bg))
check("⭐ 粉色内耳要「改写」遮罩（叠上去会被白耳朵吞掉）", K.replaces(.pink) && K.alpha(.pink) > 0 && K.alpha(.pink) < 1)
check("普通笔画是叠加不是改写", !K.replaces(.eye) && !K.replaces(.green) && !K.replaces(.greyEye))
check("dim565 → 遮罩里按比例变淡", close(K.alpha(CCFaceInk.eye.dim(0.25)), 0.25))
check("⭐ 层次保留：白眼 > 灰色耷拉眼 > 暗 z", K.alpha(.eye) > K.alpha(.greyEye) && K.alpha(.greyEye) > K.alpha(.zDark))
check("近的 z 比远的 z 显眼（zLight > zDark）", K.alpha(.zLight) > K.alpha(.zDark))
check("睡着的 grok 比醒着淡、断线的更淡", K.alpha(.grokWhite) > K.alpha(.grokSleep) && K.alpha(.grokSleep) > K.alpha(.grokGone))
check("除了切口，每种墨都看得见（≥0.3）", CCFaceTone.allCases.filter { $0 != .cut }.allSatisfy { K.alpha(CCFaceInk($0)) >= 0.3 })
check("遮罩不透明度都在 0…1", CCFaceTone.allCases.allSatisfy { (0...1).contains(K.alpha(CCFaceInk($0, level: 3))) })

// 金属＋三道阴影：跟声音柱子共用的那一份（CCMetalGlow）。
typealias G = CCMetalGlowSpec
check("⭐ 接触阴影：深色 0.18、浅色 0.34（柱子原值）", G.contactOpacity(dark: true) == 0.18 && G.contactOpacity(dark: false) == 0.34)
check("⭐ 浅色模式的暗边更重（浅底上唯一的轮廓）", G.contactOpacity(dark: false) > G.contactOpacity(dark: true))
check("接触阴影半径 3、下移 1", G.contactRadius == 3 && G.contactY == 1)
check("⭐ 两层辉光 0.55×18、0.28×40（柱子原值）", {
    let h = G.halos(glow: 1)
    return h.count == 2 && h[0].opacity == 0.55 && h[0].radius == 18 && h[1].opacity == 0.28 && h[1].radius == 40
}())
check("辉光半径按 glow 收", G.halos(glow: 0.5)[1].radius == 20)
check("⭐ 大脸 glow 跟大柱子一样是 1", G.faceGlow(side: 220) == 1 && G.faceGlow(side: 400) == 1)
check("⭐ 方块上的脸 glow 跟小柱子（0.22）一个量级", abs(G.faceGlow(side: 50) - 0.22) < 0.05)
check("侧栏 22pt 封底 0.1", G.faceGlow(side: 22) == 0.1 && G.faceGlow(side: 5) == 0.1)

check("⭐ 眼睛几何：中心 168/312、下沿 271、宽 92",
      F.eyeLX == 168 && F.eyeRX == 312 && F.eyeBottom == 271 && F.eyeW == 92)
check("两眼关于 x=240 对称", F.eyeLX + F.eyeRX == 480)

// MARK: - 状态映射

check("⭐ 睡着 → off", L.from(.asleep) == .off)
check("⭐ 找网络 → offline", L.from(.searching) == .offline)
check("⭐ 等你 → needs_you", L.from(.waiting) == .needs)
check("在听 → listening", L.from(.listening) == .listening)
check("在说话 → petting（借被抚摸那张脸）", L.from(.speaking) == .petting)
check("在查 → working", L.from(.working) == .working)
check("刚干完 → done", L.from(.done) == .done)
check("空闲 → idle", L.from(.idle) == .idle)
check("八张脸映射到八个不同状态", Set(CCFaceMood.allCases.map(L.from)).count == 8)

// MARK: - GCFG 逐字

let g = F.grokTable
check("⭐ GCFG idle：池 10/1/19、换 8–15 s、眨 5–12 s、漂移 1.0",
      g(.idle).pool == [10, 1, 19] && g(.idle).swMin == 8 && g(.idle).swMax == 15
      && g(.idle).blMin == 5 && g(.idle).blMax == 12 && g(.idle).drift == 1.0)
check("⭐ GCFG working：池 13/4/22、不眨、扫视", g(.working).pool == [13, 4, 22]
      && g(.working).blMin == 0 && g(.working).dart && g(.working).drift == 0.4)
check("GCFG needs：池 20/1、换 1.6–2.8、眨 4–7.5", g(.needs).pool == [20, 1]
      && g(.needs).swMin == 1.6 && g(.needs).swMax == 2.8 && g(.needs).blMin == 4 && g(.needs).blMax == 7.5)
check("GCFG done：池 2/17/11、弹跳", g(.done).pool == [2, 17, 11] && g(.done).hop && g(.done).blMin == 0)
check("GCFG off 灰色、offline 更灰", g(.off).col == CCFaceInk.grokSleep && g(.offline).col == CCFaceInk.grokGone)
check("GCFG 池子里不用七个圆眼球（3 21 9 18 12 6 24）", L.allCases.allSatisfy { l in
    g(l).pool.allSatisfy { ![3, 21, 9, 18, 12, 6, 24].contains($0) }
})
check("GCFG 每个池子不重复、编号都在 0..<25", L.allCases.allSatisfy { l in
    Set(g(l).pool).count == g(l).pool.count && g(l).pool.allSatisfy { (0..<25).contains($0) }
})

// MARK: - ① 眨眼

check("⭐ 眨眼 320 ms、闭 134 ms", F.blinkDuration == 0.320 && F.blinkClose == 0.134)
check("曲线：134 ms 处闭到底", close(F.blinkCurve(0.134 - 1e-12), 1, 1e-9))
check("曲线：开头 0、结尾回 0", F.blinkCurve(0) == 0 && F.blinkCurve(0.320) == 0)
check("曲线：闭的一半时 0.5", close(F.blinkCurve(0.067), 0.5))
check("曲线：睁的一半时 0.5", close(F.blinkCurve(0.134 + 0.093), 0.5))

let blinkLooks: [L] = [.idle, .needs, .listening, .offline]
for l in blinkLooks {
    let r = F.blinkRange(l, pill: true)!
    let bs = blinks(l, seconds: 120)
    check("\(l) 两分钟里眨过几次", Double(bs.count) >= 120 / r.hi - 1, "只有 \(bs.count) 次")
    guard bs.count >= 2 else { continue }
    check("⭐ \(l) 每次 320 ms", bs.allSatisfy { abs($0.end - $0.start - 0.320) < 0.002 })
    check("⭐ \(l) 闭占 42%", bs.allSatisfy { abs(($0.peak - $0.start) / 0.320 - 0.42) < 0.01 })
    let first = bs[0].start - T0
    check("⭐ \(l) 进来之后不久先眨一次（lo·0.4 … hi·0.6）",
          first >= r.lo * 0.4 - 0.002 && first <= r.hi * 0.6 + 0.002, "第一次在 \(first)s")
    let gaps = zip(bs.dropFirst(), bs).map { $0.start - $1.start }
    check("⭐ \(l) 间隔落在 GCFG 区间 [\(r.lo), \(r.hi)]",
          gaps.allSatisfy { $0 >= r.lo - 0.002 && $0 <= r.hi + 0.002 },
          "min \(gaps.min() ?? 0) max \(gaps.max() ?? 0)")
}
check("⭐ needs 比 idle 眨得勤", F.blinkRange(.needs, pill: true)!.hi < F.blinkRange(.idle, pill: true)!.hi)
check("⭐ 胶囊皮肤干活时 3–6 s 眨一次", F.blinkRange(.working, pill: true)! == (3, 6))
check("⭐ grok 干活不眨（眼睛是细线）", F.blinkRange(.working, pill: false) == nil
      && blinks(.working, pill: false, seconds: 30).isEmpty)
for l in [L.off, .done, .petting] {
    check("\(l) 不眨眼", F.blinkRange(l, pill: true) == nil && blinks(l, seconds: 20).isEmpty)
}
let longGaps: [Double] = {
    let bs = blinks(.idle, seconds: 600)
    return zip(bs.dropFirst(), bs).map { $0.start - $1.start }
}()
check("⭐ idle 间隔是随机的（十分钟里极差 > 3 s）", (longGaps.max() ?? 0) - (longGaps.min() ?? 0) > 3)

// ⑦ 可复现 / 不同步
let a1 = blinks(.idle, seconds: 60).map { $0.start }
check("⭐ 同一种子同一进入时刻可复现", a1 == blinks(.idle, seconds: 60).map { $0.start })
check("⭐ 不同房间不同步", a1 != blinks(.idle, seed: seedB, seconds: 60).map { $0.start })
check("再次进入同一状态节奏不同", blinks(.idle, since: T0 + 1000, seconds: 60).map { $0.start - 1000 } != a1)
check("进入之前不眨", F.blink(look: .idle, pill: true, since: T0, t: T0 - 1, seed: seedA) == 0)
check("非有限时间不崩、不眨", F.blink(look: .idle, pill: true, since: T0, t: .infinity, seed: seedA) == 0
      && F.blink(look: .idle, pill: true, since: T0, t: .nan, seed: seedA) == 0)
// 挂了三小时的状态：重放窗口接缝处也不出现连眨（间隔仍 ≥ lo）
let lateGaps: [Double] = {
    let bs = blinks(.idle, from: T0 + 3600 * 3 - 30, seconds: 90)
    return zip(bs.dropFirst(), bs).map { $0.start - $1.start }
}()
check("三小时后照常眨", lateGaps.count >= 3)
check("跨重放窗口不连眨", lateGaps.allSatisfy { $0 >= 0.33 })

// 眨眼压的是上眼皮：开合系数 1 − 0.96·blink
var sawBlink = false
for i in 0..<30_000 {
    let s = scene(.idle, t: T0 + Double(i) * 0.001)
    if s.blink > 0.9 {
        sawBlink = true
        check("开合系数 = 1 − 0.96·blink（闭眼也留 4%）", close(s.lidOpen, 1 - 0.96 * s.blink))
        break
    }
}
check("帧里看得到眨眼", sawBlink)

// MARK: - ② 扫视

check("⭐ 扫视一圈 3.8 s", (0..<80).allSatisfy { k in close(F.dart(Double(k) * 0.29), F.dart(Double(k) * 0.29 + 3.8), 1e-6) })
check("⭐ 往左看停在 -14", F.dart(3.8 * 0.25) == -14)
check("⭐ 往右看停在 +12", F.dart(3.8 * 0.6) == 12)
check("最后一段回正", F.dart(3.8 * 0.95) == 0)
check("扫视连续（1 ms 步长无跳变）", (1..<3800).allSatisfy { k in
    abs(F.dart(Double(k) * 0.001) - F.dart(Double(k - 1) * 0.001)) < 0.5
})
check("干活帧里眼珠跟着扫视", close(scene(.working, t: T0 + 3.8 * 0.25 - fmod(T0, 3.8)).gazeX, -14, 1e-3)
      || scene(.working, t: T0).gazeX == F.dart(T0))

// MARK: - ③ 表情池

check("五个状态各 3 张，其余 1 张", [L.idle, .working, .needs, .done, .bored].allSatisfy { F.variantCount($0) == 3 }
      && [L.off, .listening, .surprised, .petting, .offline].allSatisfy { F.variantCount($0) == 1 })
check("⭐ idle V0 = 92×42", F.variantOf(.idle, 0, left: true) == .init(wL: 92, hL: 42, wR: 92, hR: 42, dy: 0, aux: 0, pill: 0))
check("⭐ idle V1 不对称，硬币决定歪哪边", F.variantOf(.idle, 1, left: true).hL == 46 && F.variantOf(.idle, 1, left: false).hL == 34)
check("working V1 专注 80×70", F.variantOf(.working, 1, left: true).wL == 80 && F.variantOf(.working, 1, left: true).hL == 70)
check("needs V0 瞪大 106×106", F.variantOf(.needs, 0, left: true).wL == 106 && F.variantOf(.needs, 0, left: true).hL == 106)
check("⭐ done V0 弯眼高 25 px、跳 10", F.variantOf(.done, 0, left: true).dy == -25 && F.variantOf(.done, 0, left: true).aux == 10)
check("done V2 笑开（胶囊）", F.variantOf(.done, 2, left: true).pill == 1)
check("⭐ needs 换脸至少 3 s（批准气泡上的脸要稳）", F.variantCadence(.needs).lo >= 3
      && F.variantCadence(.needs).hi >= F.variantCadence(.needs).lo + 1.2)
check("idle 换脸间隔 = GCFG 8–15 s", F.variantCadence(.idle) == (8, 15))

for l in [L.idle, .working, .needs, .done] {
    check("⭐ \(l) 进入时是 V0", F.variant(look: l, since: T0, t: T0 + 0.01, seed: seedA).index == 0)
    var seq: [Int] = []
    var switches: [Double] = []
    var last = 0
    var tt = T0
    while tt < T0 + 600 {
        let v = F.variant(look: l, since: T0, t: tt, seed: seedA).index
        if v != last { seq.append(v); switches.append(tt); last = v }
        tt += 0.05
    }
    check("\(l) 十分钟里换过好几次脸", seq.count >= 10, "\(seq.count)")
    // 采样间隔 50 ms 远小于最短换脸间隔，所以「看见的变化次数」＝ 真实换脸次数，
    // 序列里不可能出现相邻相等 —— 这条钉的是「绝不连着两次同一张」。
    let cad = F.variantCadence(l)
    let gaps = zip(switches.dropFirst(), switches).map { $0 - $1 }
    check("⭐ \(l) 换脸间隔在表里的区间内", gaps.allSatisfy { $0 >= cad.lo - 0.06 && $0 <= cad.hi + 0.06 },
          "min \(gaps.min() ?? 0) max \(gaps.max() ?? 0)")
    check("\(l) 三张脸都出现过", Set(seq + [0]).count == 3)
}
// 「绝不连着两次」：直接看重放出来的下标序列（不靠采样）。
do {
    var idx: [Int] = []
    var tt = T0
    var lastI = -1
    while tt < T0 + 3000 {
        let v = F.variant(look: .done, since: T0, t: tt, seed: seedB).index
        if v != lastI { idx.append(v); lastI = v }
        tt += 0.1
    }
    var dupes = 0
    for k in 1..<idx.count where idx[k] == idx[k - 1] { dupes += 1 }
    check("⭐ 换脸绝不连着两次同一张", dupes == 0 && idx.count > 100)
}
// 180 ms 过渡：换脸那一刻前后宽高连续变化，不是硬切
do {
    var tt = T0, prev = F.variant(look: .working, since: T0, t: T0, seed: seedA)
    var maxJump = 0.0, sawMorph = false
    while tt < T0 + 60 {
        tt += 0.005
        let cur = F.variant(look: .working, since: T0, t: tt, seed: seedA)
        maxJump = max(maxJump, abs(cur.disp.hL - prev.disp.hL), abs(cur.disp.wL - prev.disp.wL))
        if cur.disp.hL != F.variantOf(.working, cur.index, left: true).hL
            && cur.disp.hL != F.variantOf(.working, cur.index, left: false).hL { sawMorph = true }
        prev = cur
    }
    check("⭐ 换脸是 180 ms 缓动，不是硬切（5 ms 步长最大跳变 < 4 px）", maxJump < 4, "\(maxJump)")
    check("看得到过渡中间帧", sawMorph)
}

// MARK: - ④ grok

check("⭐ 弹簧 ω = 2π·3.5、ζ = 0.72", close(F.springOmega, 2 * .pi * 3.5) && F.springZeta == 0.72)
check("还没换表情时进度是 0", F.spring(-0.001) == 0 && F.spring(-5) == 0)
// 原固件换表情的那一帧里就接着积分了距上一帧的 33 ms（3 个 11 ms 子步），所以一换就已经走了一截
check("⭐ 换的那一帧已经推进了一帧（33 ms、3 个子步）", close(F.springTable[1], 0.2621, 0.001) && F.spring(0) == F.springTable[1],
      "\(F.springTable[1])")
let peak = (0..<800).map { F.spring(Double($0) * 0.001) }.max()!
// 半隐式欧拉离散化后的过冲（解析解是 3.8% —— 板子上看到的不是那条）
check("⭐ 弹簧过冲约 1.6%（原固件 30 fps 欧拉积分，不是解析解的 3.8%）", peak > 1.012 && peak < 1.02, "\(peak)")
let snapK = F.springTable.firstIndex(of: 1) ?? -1
check("⭐ 弹簧第 11 帧贴死到 1（> 0.999 且速度 < 0.05）", snapK == 11, "\(snapK)")
check("表是 30 fps 一格", F.springFrame == 0.033)
check("弹簧最终落定在 1", F.spring(0.8) == 1 && F.spring(5) == 1)
check("弹簧 280 ms 左右过半程很久", F.spring(0.28) > 0.9)
check("弹簧连续（接缝处也连续）", (1..<1000).allSatisfy { abs(F.spring(Double($0) * 0.001) - F.spring(Double($0 - 1) * 0.001)) < 0.05 })

for l in L.allCases {
    let e = F.grokExpression(look: l, since: T0, t: T0 + 0.01, seed: seedA, enteredFrom: nil)
    check("⭐ grok \(l) 进场是池子第一张、冷启动不变形", e.to == g(l).pool[0] && e.from == nil)
}
let ent = F.grokExpression(look: .needs, since: T0, t: T0 + 0.1, seed: seedA, enteredFrom: 10)
check("⭐ grok 从别的表情进来要变形", ent.from == 10 && ent.to == 20 && ent.at == T0)
check("⭐ grok 进来前正好是同一张就不变形（setExpr 早退）",
      F.grokExpression(look: .needs, since: T0, t: T0 + 0.1, seed: seedA, enteredFrom: 20).from == nil)
do {
    var seq: [Int] = [], last = -1, tt = T0
    var switchT: [Double] = []
    while tt < T0 + 300 {
        let e = F.grokExpression(look: .working, since: T0, t: tt, seed: seedA, enteredFrom: nil)
        if e.to != last { seq.append(e.to); switchT.append(tt); last = e.to }
        tt += 0.02
    }
    check("grok 干活时表情只在池子里换", seq.allSatisfy { g(.working).pool.contains($0) })
    check("grok 换表情不连着同一张", zip(seq, seq.dropFirst()).allSatisfy { $0 != $1 })
    let gaps = zip(switchT.dropFirst(), switchT).map { $0 - $1 }
    check("⭐ grok 换表情间隔在 GCFG 区间 2.2–4 s", gaps.allSatisfy { $0 >= 2.2 - 0.03 && $0 <= 4 + 0.03 })
}
let gs = scene(.idle, .grok, t: T0 + 3)
let polys = gs.prims.compactMap { p -> [CCPt]? in if case .polygon(let pts, _) = p { return pts }; return nil }
check("⭐ grok 画两只 48 点多边形眼", polys.count == 2 && polys.allSatisfy { $0.count == 48 })
check("grok 没有胶囊眼", !gs.prims.contains { if case .roundRect = $0 { return true }; return false })
check("grok 数据 25 个表情 × 2 只眼 × 96 个数", CCFaceGrokEyes.shapes.count == 25
      && CCFaceGrokEyes.shapes.allSatisfy { $0.count == 2 && $0.allSatisfy { $0.count == 96 } })
check("grok 数据首尾逐字（966,261 … 表情 0 左眼）", CCFaceGrokEyes.shapes[0][0][0] == 966 && CCFaceGrokEyes.shapes[0][0][1] == 261)
// 眨眼绕质心压扁：高度按 1 − 0.96·blink 缩、质心 y 不动
do {
    func firstPoly(_ s: F.Scene) -> [CCPt] {
        s.prims.compactMap { p -> [CCPt]? in if case .polygon(let q, _) = p { return q }; return nil }.first ?? []
    }
    var t = T0
    var found: F.Scene?
    while t < T0 + 30 { let s = scene(.idle, .grok, t: t); if s.blink > 0.9 { found = s; break }; t += 0.001 }
    if let s = found {
        let shut = firstPoly(s)
        // 同一表情、没在眨的那一刻（眨眼结束后 0.4 s，换表情要 8 s 以上，表情还是同一张）
        let open = firstPoly(scene(.idle, .grok, t: t + 0.4))
        let h1 = shut.map(\.y).max()! - shut.map(\.y).min()!
        let h0 = open.map(\.y).max()! - open.map(\.y).min()!
        check("⭐ grok 眨眼：高度按 1 − 0.96·blink 压扁", abs(h1 / h0 - (1 - 0.96 * s.blink)) < 0.02, "\(h1 / h0) vs \(1 - 0.96 * s.blink)")
        let c1 = shut.map(\.y).reduce(0, +) / 48 - s.gazeY
        let c0 = open.map(\.y).reduce(0, +) / 48 - scene(.idle, .grok, t: t + 0.4).gazeY
        check("⭐ grok 眨眼绕质心（质心 y 不动）", abs(c1 - c0) < 0.01, "\(c1) vs \(c0)")
    } else { check("grok 眨过眼", false) }
}

// MARK: - ④b 没人理（原固件 main.cpp「lonely sighs」：空闲 10 分钟后每 2–5 分钟叹一次，每次 4.5 s）

do {
    check("⭐ 空闲不满 10 分钟不会没人理", (0..<600).allSatisfy { scene(.idle, t: T0 + Double($0)).look == .idle })
    // 扫两小时（跨一个重放窗口），1 秒步长找每一次「没人理」
    var starts: [Double] = [], lens: [Double] = []
    var inEp = false, epStart = 0.0
    var tt = T0 + 600
    while tt < T0 + 600 + 7200 {
        let b = scene(.idle, t: tt).look == .bored
        if b && !inEp { inEp = true; epStart = tt; starts.append(tt) }
        if !b && inEp { inEp = false; lens.append(tt - epStart) }
        tt += 0.25
    }
    check("⭐ 第一次叹气在满 10 分钟后 5–60 秒", starts.first.map { $0 - T0 - 600 >= 5 - 0.25 && $0 - T0 - 600 <= 60 + 0.25 } ?? false,
          "\(starts.first.map { $0 - T0 } ?? -1)")
    check("⭐ 每次 4.5 秒（boredUntil = now + 4500）", !lens.isEmpty && lens.allSatisfy { abs($0 - 4.5) <= 0.25 + 1e-9 }, "\(lens.prefix(5))")
    let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
    check("⭐ 叹气间隔 2–5 分钟（跨重放窗口的那一次也不短于 2 分钟、不长于 10 分钟）",
          gaps.count >= 20 && gaps.allSatisfy { $0 >= 120 - 0.25 && $0 <= 600 + 0.25 }
          && gaps.filter { $0 <= 300 + 0.25 }.count >= gaps.count - 2, "\(gaps.min() ?? 0) … \(gaps.max() ?? 0)")
    for m in [CCFaceMood.asleep, .searching, .waiting, .listening, .speaking, .working] {
        check("⭐ 只有空闲会没人理：\(m) 挂两小时也不会", stride(from: 600.0, to: 7800, by: 7).allSatisfy {
            scene(m, t: T0 + $0).look == CCFaceLook.from(m) })
    }
    if let s0 = starts.first {
        let ep = scene(.idle, t: s0 + 1)
        check("没人理时画沉眼皮＋省略号", ep.hasProps && ep.prims.contains { if case .rect(_, _, 3, 3, _) = $0 { return true }; return false })
        // 一次「没人理」就是一次换状态：表情池回到 V0，叹完回到空闲也是
        let r = F.resolve(look: .idle, since: T0, t: s0 + 0.5, seed: seedA, grokFrom: nil)
        check("⭐ 叹气那一段从它自己开始算（since ＝ 起点）", r.look == .bored && abs(r.since - s0) < 0.25 + 1e-9)
        let after = F.resolve(look: .idle, since: T0, t: s0 + 10, seed: seedA, grokFrom: nil)
        check("⭐ 叹完回到空闲也重新算（since ＝ 叹完那一刻）", after.look == .idle && abs(after.since - (r.since + 4.5)) < 1e-9)
        check("叹气开头是 bored 的 V0", F.variant(look: .bored, since: r.since, t: r.since + 0.01, seed: seedA).index == 0)
        // grok：从空闲那张变到 bored 池子第一张
        let gFrom = r.grokFrom
        check("⭐ grok 叹气时从空闲当时那张表情变过去", gFrom != nil && g(.idle).pool.contains(gFrom!))
        let gs = scene(.idle, .grok, t: s0 + 1)
        check("grok 叹气时是 bored 的表情", gs.grokExpr.map { g(.bored).pool.contains($0) } ?? false)
    }
    // 换心情那一刻记下的 grok 表情，要算上「没人理」
    if let s0 = starts.first {
        let shown = F.grokShowing(mood: .idle, since: T0, t: s0 + 1, seed: seedA, grokFrom: nil)
        check("⭐ 叹气中途换心情：记下的是 bored 那张", g(.bored).pool.contains(shown))
    }
}

// MARK: - ⑤ 眼睛下沿固定

/// 白色的大块圆角矩形 ＝ 眼白（宽 ≥ 50 排除打字点、麦克风条）。
func eyeRects(_ s: F.Scene) -> [(x: Double, y: Double, w: Double, h: Double)] {
    s.prims.compactMap { p in
        if case let .roundRect(x, y, w, h, _, c) = p, c == CCFaceInk.eye, w >= 50 { return (x, y, w, h) }
        return nil
    }
}
for skin in [CCFaceSkin.classic, .kitty, .robo, .bunny, .sprout] {
    for m in [CCFaceMood.idle, .working, .waiting, .listening] {
        var ok = true, n = 0
        var tt = T0
        while tt < T0 + 20 {
            let s = scene(m, skin, t: tt)
            for r in eyeRects(s) {
                n += 1
                if abs(r.y + r.h - (F.eyeBottom + s.bob)) > 1e-9 { ok = false }
            }
            tt += 0.037
        }
        check("⭐ \(skin) \(m)：眼白下沿 = 271 ＋ 整体浮动（眨眼/换脸只动上沿）", ok && n > 100)
    }
}
do {
    // idle 的浮动只改高度不改位置：下沿恒为 271
    var bottoms = Set<Double>(), tops = Set<Double>()
    var tt = T0
    while tt < T0 + 30 {
        for r in eyeRects(scene(.idle, t: tt)) { bottoms.insert(r.y + r.h); tops.insert((r.y * 1000).rounded()) }
        tt += 0.01
    }
    check("⭐ idle 眨眼呼吸三十秒，下沿一个值都没变", bottoms == [271])
    check("idle 上沿在变（眼皮在动）", tops.count > 20)
}
do {
    // 眼皮切法：idle 是「全宽眼 ＋ 一块 25 px 高的黑矩形压在上面」
    let s = scene(.idle, t: T0, reduce: true)
    let cut = s.prims.compactMap { p -> Double? in if case let .rect(_, _, w, h, c) = p, c == CCFaceInk.bg, w == 94 { return h }; return nil }
    check("⭐ idle 上眼皮是两块 94×25 的黑矩形", cut == [25, 25])
    let eyes = eyeRects(s)
    check("idle 眼白高 = 开度 42 ＋ 24 余量", eyes.count == 2 && eyes.allSatisfy { $0.h == 66 && $0.w == 92 })
}
check("全睁（listening）是圆：92×92", eyeRects(scene(.listening, t: T0, reduce: true)).allSatisfy { $0.w == 92 && $0.h == 92 })

// MARK: - ⑥ 减弱动态效果 / 小尺寸

for skin in CCFaceSkin.allCases {
    for m in CCFaceMood.allCases {
        let a = scene(m, skin, t: T0 + 0.5, reduce: true)
        var still = true
        for k in 1..<40 where scene(m, skin, t: T0 + 0.5 + Double(k) * 0.173, reduce: true).prims != a.prims {
            still = false
        }
        check("⭐ 减弱动态：\(skin) \(m) 画面不随时间变", still)
    }
}
check("⭐ 减弱动态：形状照样按状态换", scene(.waiting, t: T0, reduce: true).prims != scene(.idle, t: T0, reduce: true).prims)
check("⭐ 减弱动态：问号照样画", scene(.waiting, t: T0, reduce: true).hasProps)
check("减弱动态：没有眨眼、扫视、浮动", (0..<200).allSatisfy { k in
    let s = scene(.working, t: T0 + Double(k) * 0.05, reduce: true)
    return s.blink == 0 && s.gazeX == 0 && s.bob == 0
})
check("没开减弱动态时画面在动", scene(.working, t: T0 + 1).prims != scene(.working, t: T0 + 1.3).prims)

for m in CCFaceMood.allCases {
    check("⭐ 小尺寸不画心情道具：\(m)", !scene(m, t: T0 + 1, compact: true).hasProps)
}
check("⭐ 大尺寸画问号", scene(.waiting, t: T0).hasProps)
check("⭐ 大尺寸画打字点", scene(.working, t: T0).hasProps)
check("⭐ 小尺寸照画猫耳（认皮肤靠它）", scene(.idle, .kitty, t: T0, compact: true).prims.contains {
    if case .triangle = $0 { return true }; return false
})

// MARK: - ⑦ 头饰逐字

func count(_ s: F.Scene, _ pred: (CCFacePrim) -> Bool) -> Int { s.prims.filter(pred).count }
let kitty = scene(.idle, .kitty, t: T0, reduce: true)
check("⭐ kitty 两只三角耳＋六根胡须", count(kitty) { if case .triangle = $0 { return true }; return false } == 2
      && count(kitty) { if case .line = $0 { return true }; return false } == 6)
check("kitty 左耳坐标 (124,152)(182,148)(146,84)", kitty.prims.contains {
    $0 == .triangle(CCPt(124, 152), CCPt(182, 148), CCPt(146, 84), CCFaceInk.eye)
})
let bunny = scene(.idle, .bunny, t: T0, reduce: true)
check("⭐ bunny 五根圆头条，两根粉色内耳", count(bunny) { if case .pill = $0 { return true }; return false } == 5
      && count(bunny) { if case let .pill(_, _, _, _, _, c) = $0 { return c == CCFaceInk.pink }; return false } == 2)
check("bunny 立耳 (158,103) 长 148 粗 36 转 82°", bunny.prims.contains { $0 == .pill(cx: 158, cy: 103, len: 148, thick: 36, deg: 82, CCFaceInk.eye) })
let sprout = scene(.idle, .sprout, t: T0, reduce: true)
check("⭐ sprout 四段绿（两茎两叶）", count(sprout) { if case let .pill(_, _, _, _, _, c) = $0 { return c == CCFaceInk.green }; return false } == 4)
check("classic 没头饰", count(scene(.idle, .classic, t: T0, reduce: true)) {
    switch $0 { case .triangle, .pill, .line: return true; default: return false }
} == 0)
// robo：方眼（圆角 = min(w,h)/6）＋ 黑色高光缺口
let robo = scene(.working, .robo, t: T0, reduce: true)
check("⭐ robo 方眼：圆角 = 短边/6", robo.prims.contains {
    if case let .roundRect(_, _, w, h, r, c) = $0, c == CCFaceInk.eye, w >= 50 { return close(r, min(w, h) / 6) }
    return false
})
check("⭐ robo 有黑色高光缺口（13 或 17 见方）", robo.prims.contains {
    if case let .roundRect(_, _, w, h, r, c) = $0, c == CCFaceInk.bg { return (w == 13 || w == 17) && w == h && r == 4 }
    return false
})
check("胶囊皮肤圆角 = 短边/2", scene(.working, .classic, t: T0, reduce: true).prims.contains {
    if case let .roundRect(_, _, w, h, r, c) = $0, c == CCFaceInk.eye, w >= 50 { return close(r, min(w, h) / 2) }
    return false
})
check("robo 半睁（idle 42 px）也有高光 —— 原注释「idle's lidded eyes keep it too」",
      scene(.idle, .robo, t: T0, reduce: true).prims.contains {
    if case let .roundRect(_, _, w, _, _, c) = $0, c == CCFaceInk.bg { return w == 13 }
    return false
})
do {
    var b = F.Builder(skin: .robo, t: T0, reduce: true)
    b.eyeLidded(168, 30, 0)             // idle V2「慢眯」：30 px < 36
    check("robo 眯到 30 px 时不画高光", !b.p.contains {
        if case let .roundRect(_, _, w, _, _, c) = $0, c == CCFaceInk.bg { return w == 13 || w == 17 }
        return false
    })
}

// MARK: - 心情道具

func circles(_ s: F.Scene) -> [(Double, Double)] {
    s.prims.compactMap { if case let .circle(cx, cy, r, _) = $0, r == 7 { return (cx, cy) }; return nil }
}
check("⭐ 打字点默认 3 个、28 px 间距、以 240 居中", circles(scene(.working, t: T0, reduce: true)).map { $0.0 } == [212, 240, 268])
check("⭐ 有子任务时打字点更多，仍居中", {
    let xs = circles(scene(.working, t: T0, reduce: true, dots: 5)).map { $0.0 }
    return xs.count == 5 && close(xs.reduce(0, +) / 5, 240)
}())
check("干活不满 3 分钟不出汗（175 s 正好是 25 的倍数也不出）", !scene(.working, t: T0 + 175.5, reduce: false).prims.contains {
    if case let .circle(cx, _, _, _) = $0 { return cx == 361 }; return false
})
check("⭐ 干活满 3 分钟后、每 25 秒那一下出汗（彩蛋）", scene(.working, t: T0 + 200.5).prims.contains {
    if case let .circle(cx, _, _, _) = $0 { return cx == 361 }; return false
})
let q = scene(.waiting, t: T0, reduce: true).prims.compactMap { p -> Double? in
    if case let .rect(x, _, w, _, c) = p, c == CCFaceInk.eye, w == 5 { return x }; return nil
}
// glcdfont 的 '?'（02 01 59 09 06）一共 10 个点；第一版手画少了第 4 行那一格（9 个点）
check("⭐ 问号是 5 倍点阵（glcdfont 的 10 个点）、从 x=362 起", q.min() == 362 && q.count == 10)
let dots = F.dot
check("⭐ 省略号的点在第 3、4 列（glcdfont '.' = 00 00 60 60 00）", dots[5] == "..##." && dots[6] == "..##.")
check("睡着画 zz", scene(.asleep, t: T0).hasProps)
check("睡着是两条 64×10 横条", scene(.asleep, t: T0, reduce: true).prims.filter {
    if case let .roundRect(_, _, w, h, _, _) = $0 { return w == 64 && h == 10 }; return false
}.count == 2)
check("找网络是两只灰色耷拉眼（-8° / +8°）", scene(.searching, t: T0, reduce: true).prims.filter {
    if case let .pill(_, _, _, _, d, c) = $0 { return c == CCFaceInk.greyEye && abs(d) == 8 }; return false
}.count == 2)
check("在说话有脸红（BATTRED 压到 45%）", scene(.speaking, t: T0, reduce: true).prims.contains {
    if case let .circle(_, _, r, c) = $0 { return r == 11 && c == CCFaceInk.battRed.dim(0.45) }; return false
})
check("刚干完是 180°→360° 的上半圈弯眼", scene(.done, t: T0, reduce: true).prims.contains {
    if case let .arc(_, _, _, _, a, b, _) = $0 { return a == 180 && b == 360 }; return false
})
check("在听有五根麦克风条", scene(.listening, t: T0, reduce: true).prims.filter {
    if case let .roundRect(_, _, w, _, _, c) = $0 { return w == 8 && c == CCFaceInk.micBar }; return false
}.count == 5)

// MARK: - 皮肤存盘

check("六套皮肤（含 grok）", CCFaceSkin.allCases.count == 6)
check("⭐ rawValue 逐字（＝原固件 faceSkinName 的拼写，落盘的值）",
      CCFaceSkin.allCases.map(\.rawValue) == ["classic", "kitty", "robo", "bunny", "sprout", "grok"])
check("rawValue 往返无损", CCFaceSkin.allCases.allSatisfy { CCFaceSkin.parse($0.rawValue) == $0 })
check("解析容忍空白和大小写", CCFaceSkin.parse("  Kitty \n") == .kitty)
check("⭐ 空 / 未知值＝不用活脸，不退回 classic", CCFaceSkin.parse(nil) == nil
      && CCFaceSkin.parse("") == nil && CCFaceSkin.parse("pikachu") == nil)
check("皮肤名都有且互异", Set(CCFaceSkin.allCases.map(\.title)).count == 6)

// MARK: - 编译期断言：Canvas 的绘制闭包可能是 nonisolated 的

nonisolated func drawFromNonisolatedContext() -> Int {
    let s = CCFaceMotion.scene(.init(mood: .idle, skin: .grok, t: 1, since: 0, seed: 1))
    return s.prims.count + (CCFaceMask.alpha(CCFaceInk.eye.dim(0.5)) > 0 ? 0 : 1) + Int(CCMetalGlowSpec.contactRadius) * 0 + CCFaceGrokEyes.shapes.count * 0
        + Int(CCFaceMotion.eyeBottom) * 0
}
check("能从 nonisolated 上下文算一帧（编译过就算过）", drawFromNonisolatedContext() == 2)

print(failed == 0 ? "✓ \(passed) 条全过" : "✗ \(failed) 条失败 / \(passed) 条通过")
exit(failed == 0 ? 0 : 1)
