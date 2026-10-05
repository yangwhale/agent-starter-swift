// 活脸「哪张脸」的测试 —— CCFaceMood ＋ 叮声的边沿检测与去重。
//
// 要钉住的是几条「写错了日常也看不出来」的规则：
//   ① 没连上时其它信号一律不看（断线时 wait/on 是过期残值）；
//   ② 「等你」排在「在说话」前面（唯一要你动手的状态不能被盖住）；
//   ③ 「刚干完」只挂 3 秒，用的是**传入的时间**，左闭右开、时间倒退不算；
//   ④ 叮声只认边沿：刚连上的第一份状态不叮，wait 一直挂着不重复叮；
//   ⑤ 同一事件 3 秒内只叮一次，不同房间/不同事件互不挡。
//
// 跑法见 Tests/README.md：
//
//   mkdir -p /tmp/swtest && cp VoiceAgent/CloseCrab/CCPresence.swift VoiceAgent/CloseCrab/CCFaceMood.swift /tmp/swtest/
//   cp Tests/CCFaceMoodTests.swift /tmp/swtest/main.swift
//   docker run --rm -v /tmp/swtest:/w -w /w swift:6.2-noble \
//     bash -c 'swiftc -swift-version 6 -default-isolation MainActor \
//                CCPresence.swift CCFaceMood.swift main.swift -o t && ./t'

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

typealias M = CCFaceMood
let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

func mood(_ p: CCPresenceDot = .online, wait: String = "", on: Bool = false,
          hold: Bool = false, speak: Bool = false, muted: Bool = false,
          doneAt: Date? = nil, now: Date = t0) -> M {
    M.derive(presence: p, wait: wait, on: on, holding: hold, speaking: speak,
             muted: muted, finishedAt: doneAt, now: now)
}

// MARK: - ⭐ 要害

check("⭐ 灰点＝睡着，哪怕残留着「等你」「在忙」",
      mood(.off, wait: "批准方案", on: true, hold: true, speak: true, doneAt: t0) == .asleep)
check("⭐ 黄点＝迷糊找人，不看残值", mood(.connecting, wait: "x", on: true, speak: true) == .searching)
check("⭐ 红点（断线重试）也是迷糊找人", mood(.retrying, wait: "x", on: true) == .searching)
check("⭐ 等你 > 在说话", mood(wait: "批准方案", speak: true) == .waiting)
check("⭐ 等你 > 在听你说", mood(wait: "批准方案", hold: true) == .waiting)
check("⭐ 刚干完：事件当刻就是 done", mood(doneAt: t0, now: t0) == .done)
check("⭐ 刚干完：2.999 秒还是 done", mood(doneAt: t0, now: t0 + 2.999) == .done)
check("⭐ 刚干完：满 3 秒回空闲（右开）", mood(doneAt: t0, now: t0 + 3) == .idle)
check("⭐ 时间倒退不算刚干完", mood(doneAt: t0, now: t0 - 0.5) == .idle)
check("⭐ 静音时不画「在说话」（笑着张嘴却没声＝像坏了）", mood(speak: true, muted: true) == .idle)

// 窗口长度只钉需求区间：要看得见（≥1.5 秒），又不能挡住下一轮（≤5 秒）。
check("刚干完窗口 ≥1.5 秒", M.doneWindow >= 1.5)
check("刚干完窗口 ≤5 秒", M.doneWindow <= 5)
check("刚干完窗口就是方案里的 3 秒", M.doneWindow == 3)

// MARK: - 优先级链：从上往下逐个打开信号，每一档都必须压住下面所有档

check("在听你说 > 在说话", mood(hold: true, speak: true) == .listening)
check("在说话 > 在查东西", mood(on: true, speak: true) == .speaking)
check("在查东西 > 刚干完", mood(on: true, doneAt: t0) == .working)
check("静音时在说话落到在查东西", mood(on: true, speak: true, muted: true) == .working)
check("什么都没有＝空闲", mood() == .idle)
check("没有干完时刻＝空闲", mood(doneAt: nil) == .idle)
check("橙点照常往下判（连着，只是网差/bot 不在）", mood(.degraded, on: true) == .working)
check("橙点＋什么都没有＝空闲", mood(.degraded) == .idle)

// MARK: - 真值表：连着时 5 个布尔 × 干完窗口内外，全组合对照参考实现

func reference(wait: Bool, hold: Bool, speak: Bool, muted: Bool, on: Bool, inDone: Bool) -> M {
    if wait { return .waiting }
    if hold { return .listening }
    if speak && !muted { return .speaking }
    if on { return .working }
    if inDone { return .done }
    return .idle
}

var rows = 0
for p in [CCPresenceDot.online, .degraded] {
    for w in [false, true] { for h in [false, true] { for s in [false, true] {
        for mu in [false, true] { for o in [false, true] { for d in [false, true] {
            let got = mood(p, wait: w ? "等你" : "", on: o, hold: h, speak: s, muted: mu,
                           doneAt: t0, now: d ? t0 + 1 : t0 + 10)
            let want = reference(wait: w, hold: h, speak: s, muted: mu, on: o, inDone: d)
            check("真值表 p=\(p) w=\(w) h=\(h) s=\(s) m=\(mu) on=\(o) d=\(d)", got == want,
                  "得到 \(got) 应为 \(want)")
            rows += 1
        } } }
    } } }
}
check("真值表覆盖 128 行", rows == 128)

// 没连上时：任意组合都只看小圆点。
for p in [CCPresenceDot.off, .connecting, .retrying] {
    for w in [false, true] { for h in [false, true] { for s in [false, true] { for o in [false, true] {
        let got = mood(p, wait: w ? "x" : "", on: o, hold: h, speak: s, doneAt: t0, now: t0 + 1)
        check("未连接不看信号 p=\(p) w=\(w) h=\(h) s=\(s) on=\(o)",
              got == (p == .off ? .asleep : .searching))
    } } } }
}

// MARK: - 打字点

check("没子任务 3 个点", M.typingDots(runningSubtasks: 0) == 3)
check("⭐ 有子任务点更多", M.typingDots(runningSubtasks: 1) > M.typingDots(runningSubtasks: 0))
check("封顶 5 个", M.typingDots(runningSubtasks: 40) == 5)
check("负数当 0", M.typingDots(runningSubtasks: -3) == 3)

// MARK: - 读屏

check("八张脸", M.allCases.count == 8)
check("每张脸都有读屏文字", M.allCases.allSatisfy { !$0.spoken.isEmpty })
check("读屏文字互不相同", Set(M.allCases.map(\.spoken)).count == M.allCases.count)

// MARK: - 叮声：边沿检测

typealias E = CCFaceEvent
func ev(_ pOn: Bool?, _ pWait: String?, _ on: Bool, _ wait: String, _ sum: String = "") -> E? {
    E.detect(prevOn: pOn, prevWait: pWait, nextOn: on, nextWait: wait, nextSum: sum)
}

check("⭐ wait 空→非空 叮「等你」", ev(true, "", true, "批准方案") == .waiting)
check("⭐ wait 一直挂着不重复叮", ev(true, "批准方案", true, "批准方案") == nil)
check("wait 换了一句话也不叮（还是同一段在等）", ev(true, "批准方案", true, "回答问题") == nil)
check("⭐ on 真→假且有总结 叮「干完」", ev(true, "", false, "", "改好了") == .finished)
check("⭐ on 真→假但没总结 不叮（被打断/取消不是干完）", ev(true, "", false, "", "") == nil)
check("on 一直假 不叮", ev(false, "", false, "", "改好了") == nil)
check("on 假→真 不叮", ev(false, "", true, "") == nil)
check("⭐ 刚连上的第一份（没有上一份）不叮，哪怕在等你", ev(nil, nil, true, "批准方案") == nil)
check("刚连上的第一份带总结也不叮", ev(nil, nil, false, "", "改好了") == nil)
check("⭐ 干完同时开始等你 → 报「等你」", ev(true, "", false, "批准方案", "改好了") == .waiting)
check("wait 非空→空 不叮", ev(true, "批准方案", true, "") == nil)

// MARK: - 叮声：3 秒去重

var g = CCChimeGate()
check("⭐ 第一次响", g.admit("jarvis|waiting", at: 100))
check("⭐ 2.9 秒内不重复", !g.admit("jarvis|waiting", at: 102.9))
check("⭐ 别的事件不受挡", g.admit("jarvis|finished", at: 102.9))
check("⭐ 别的房间不受挡", g.admit("bunny|waiting", at: 101))
check("满 3 秒再响", g.admit("jarvis|waiting", at: 103))
check("被挡掉的那次不刷新起点（从 103 起算）", !g.admit("jarvis|waiting", at: 105.9))
check("从 103 起算满 3 秒", g.admit("jarvis|waiting", at: 106))
check("时间倒退按该响处理", g.admit("jarvis|waiting", at: 50))
check("倒退后重新记起点", !g.admit("jarvis|waiting", at: 51))
check("去重窗口是 3 秒", CCChimeGate.window == 3)

// MARK: - 编译期断言：画脸的闭包可能是 nonisolated 的

nonisolated func readFromNonisolatedContext() -> Int {
    let m = CCFaceMood.derive(presence: .online, wait: "", on: true, holding: false,
                              speaking: false, muted: false, finishedAt: nil, now: Date())
    var gate = CCChimeGate()
    _ = gate.admit("k", at: 0)
    _ = CCFaceEvent.detect(prevOn: nil, prevWait: nil, nextOn: false, nextWait: "", nextSum: "")
    return CCFaceMood.typingDots(runningSubtasks: 0) + (m == .working ? 1 : 0)
}
check("能从 nonisolated 上下文调用（编译过就算过）", readFromNonisolatedContext() == 4)

print(failed == 0 ? "✓ \(passed) 条全过" : "✗ \(failed) 条失败 / \(passed) 条通过")
exit(failed == 0 ? 0 : 1)
