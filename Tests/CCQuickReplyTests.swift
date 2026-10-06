// 快捷回复的共用规则（`CCQuickReply`）—— app 主界面那两颗按钮和锁屏实时活动用的是同一份。
//
// 要钉住的：
//   ① 发给 bot 的是 Chris 定的两句完整原句；简写只用于显示、而且真的更短；
//   ② 只在「等你回话」（脸是 .waiting）时出现 —— 判据是脸不是 wait 字段：
//      断线时 wait 是残值、按住说话时脸是「在听」，这两种都不出；
//   ③ 点完立刻换成「已回复：<完整原句>」，恰好 3 秒（左闭右开、时钟倒退不算），
//      这 3 秒里不管还等不等都显示它、不出按钮；过了 3 秒还在等就重新出按钮；
//   ④ 按钮上方那句 = wait 去空白、按字符截到 40（含省略号）。
//
// 跑法见 Tests/README.md：
//
//   mkdir -p /tmp/swtest && cd VoiceAgent/CloseCrab && cp CCPresence.swift CCFaceMood.swift CCQuickReply.swift /tmp/swtest/
//   cp Tests/CCQuickReplyTests.swift /tmp/swtest/main.swift
//   docker run --rm -v /tmp/swtest:/w -w /w swift:6.2-noble \
//     bash -c 'swiftc -swift-version 6 -default-isolation MainActor \
//                CCPresence.swift CCFaceMood.swift CCQuickReply.swift main.swift -o t && ./t'

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

typealias Q = CCQuickReply
let t0 = Date(timeIntervalSinceReferenceDate: 0)
func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }

// MARK: - ① 文字

check("⭐ 发给 bot 的是 Chris 定的两句完整原句", Q.choices.map(\.text) == ["没问题，请继续", "按照你的想法来"])
check("按钮放不下时的简写", Q.choices.map(\.short) == ["请继续", "按你的来"])
check("简写真的更短（否则 ViewThatFits 那一步没意义）", Q.choices.allSatisfy { $0.short.count < $0.text.count })
check("两句互不相同", Set(Q.choices.map(\.text)).count == 2)
check("两句都在服务端 1–2000 字范围内", Q.choices.allSatisfy { !$0.text.isEmpty && $0.text.count <= 2000 })
check("两颗图标不同", Set(Q.choices.map(\.symbol)).count == 2)

// MARK: - ② 何时出现

func disp(_ mood: CCFaceMood, wait: String = "等你批准方案", text: String? = nil, at a: Date? = nil,
          now: Date = t0) -> Q.Display {
    Q.display(mood: mood, wait: wait, repliedText: text, repliedAt: a, now: now)
}
check("⭐ 等你回话 ⇒ 出按钮，带上 bot 等的那句", disp(.waiting) == .offer(prompt: "等你批准方案"))
for m in [CCFaceMood.asleep, .searching, .listening, .speaking, .working, .done, .idle] {
    check("⭐ \(m.rawValue) ⇒ 不出（离开等你自动收起）", disp(m) == .hidden)
}
check("等你但 wait 是空白 ⇒ 照出按钮，提示那行为空", disp(.waiting, wait: "  \n") == .offer(prompt: ""))

// 跟脸同一份规则：wait 残值 + 断线、wait + 按住说话 —— 用真的 derive 走一遍
func moodOf(presence: CCPresenceDot, wait: String, holding: Bool) -> CCFaceMood {
    CCFaceMood.derive(presence: presence, botPresent: true, wait: wait, on: false, holding: holding,
                      speaking: false, muted: false, finishedAt: nil, now: t0)
}
check("⭐ 断线（wait 是残值）⇒ 不出", disp(moodOf(presence: .retrying, wait: "要继续吗？", holding: false)) == .hidden)
check("⭐ 按住说话时（脸是在听）⇒ 不出", disp(moodOf(presence: .online, wait: "要继续吗？", holding: true)) == .hidden)
check("连着、有 wait、没按住 ⇒ 出", disp(moodOf(presence: .online, wait: "要继续吗？", holding: false), wait: "要继续吗？")
      == .offer(prompt: "要继续吗？"))

// MARK: - ③ 已回复

let txt = "没问题，请继续"
check("⭐ 点完那一刻 ⇒ 已回复（完整原句）", disp(.waiting, text: txt, at: t0, now: t0) == .replied("已回复：没问题，请继续"))
check("2.999 秒 ⇒ 仍是已回复", disp(.waiting, text: txt, at: t0, now: at(2.999)) == .replied("已回复：没问题，请继续"))
check("⭐ 正好 3 秒、还在等 ⇒ 重新出按钮", disp(.waiting, text: txt, at: t0, now: at(3)) == .offer(prompt: "等你批准方案"))
check("⭐ 已回复窗口里 bot 已经不等了 ⇒ 仍显示已回复（留够 3 秒读得到）",
      disp(.working, text: txt, at: t0, now: at(1)) == .replied("已回复：没问题，请继续"))
check("窗口过了、也不等了 ⇒ 消失", disp(.working, text: txt, at: t0, now: at(3)) == .hidden)
check("时钟往回拨 ⇒ 不算刚回复", disp(.waiting, text: txt, at: at(10), now: t0) == .offer(prompt: "等你批准方案"))
check("只有时刻没有文字 ⇒ 不算", disp(.waiting, text: nil, at: t0, now: t0) == .offer(prompt: "等你批准方案"))
check("显示窗口是 3 秒", Q.repliedShowFor == 3)
check("repliedLine 直接调", Q.repliedLine(text: "按照你的想法来", at: t0, now: at(1)) == "已回复：按照你的想法来")
check("重算时刻 ＝ 点击时刻 ＋ 3 秒", Q.repliedRecheck(at: t0, now: at(1)) == at(3))
check("窗口外不定闹钟", Q.repliedRecheck(at: t0, now: at(3)) == nil && Q.repliedRecheck(at: nil, now: t0) == nil
      && Q.repliedRecheck(at: at(10), now: t0) == nil)

// MARK: - ④ 提示那句

check("提示去空白", Q.prompt(wait: "  要不要先压高度？\n") == "要不要先压高度？")
check("恰好 40 字不截", Q.prompt(wait: String(repeating: "好", count: 40)) == String(repeating: "好", count: 40))
let long = Q.prompt(wait: String(repeating: "长", count: 100))
check("超了截到 40（含省略号）", long.count == Q.promptMax && long.hasSuffix("…") && Q.promptMax == 40)

// MARK: - ⑤ bot 推荐的答案（2026-10-06：`<ask-user>摘要|答案一|答案二</ask-user>` → 快照 opts）

check("⭐ 没带推荐答案 ⇒ 固定那两句", Q.choices(options: nil) == Q.choices && Q.choices(options: []) == Q.choices)
check("⭐ 带了 ⇒ 用 bot 的，原句照发", Q.choices(options: ["先修麦克风", "先做切房间"]).map(\.text) == ["先修麦克风", "先做切房间"])
check("推荐答案没有另外的简写", Q.choices(options: ["先修麦克风"]).allSatisfy { $0.short == $0.text })
check("只带一个就一颗，不凑固定句", Q.choices(options: ["好"]).map(\.text) == ["好"])
check("去空白、去空串、去重", Q.choices(options: [" A ", "", "  ", "A", "B"]).map(\.text) == ["A", "B"])
check("⭐ 最多两颗", Q.choices(options: ["A", "B", "C"]).count == 2 && Q.maxOptions == 2)
check("全是空白 ⇒ 退回固定那两句", Q.choices(options: [" ", "\n"]) == Q.choices)
check("两颗图标不同（最推荐的是星）", Q.choices(options: ["A", "B"]).map(\.symbol) == ["star", "arrow.turn.down.right"])

// MARK: - 从 nonisolated 上下文用（扩展的视图、ActivityKit 线程会读；编译过就算过）

nonisolated func touch() -> Int {
    let d = Q.display(mood: .waiting, wait: "x", repliedText: nil, repliedAt: nil, now: Date())
    return Q.choices.count + Q.choices(options: ["a"]).count + (d == .hidden ? 0 : 1) + Q.prompt(wait: "y").count
        + (Q.repliedLine(text: "a", at: Date(), now: Date()) ?? "").count
}
check("能从 nonisolated 上下文用（编译过就算过）", touch() > 0)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
