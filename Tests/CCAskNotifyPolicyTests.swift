// 「bot 在等你」本地通知的规则测试（`CCAskNotifyPolicy`）。
//
// 要钉住的是几条「写错了日常也看不出来」的：
//   ① 按边沿发：一句挂着的问题只响一次，过了 60 秒也不会自己再响（快照每 0.5 秒来一份）；
//   ② 问题出现时 app 在前台 ⇒ 不发，而且之后切到后台也不补发；
//   ③ 找网络（重连中）不发也不撤，回来还是那句 ⇒ 不算新问题；挂断 / bot 不在才撤；
//   ④ 回答过了就撤（任何一处点的都算），但上一个问题的回复撤不掉这一个；
//   ⑤ 同一房间同一句 60 秒内不重复发（左闭右开、分房间、去空白、时钟倒退不算）；
//   ⑥ 按住说话（脸是「在听」）不算在等 —— 跟快捷回复条同一个判据（拿真 derive 走）；
//   ⑦ 按钮跟 app 主界面同一份（推荐答案 / 固定两句），按下标从 userInfo 取回完整原句；
//      category id 只跟按钮内容有关、换一组就换、字段边界不会撞。
//
// 跑法见 Tests/README.md：
//
//   mkdir -p /tmp/swt-notif && cd VoiceAgent/CloseCrab && cp CCPresence.swift CCFaceMood.swift \
//     CCQuickReply.swift CCAskNotifyPolicy.swift /tmp/swt-notif/
//   cp Tests/CCAskNotifyPolicyTests.swift /tmp/swt-notif/main.swift
//   docker run --rm -v /tmp/swt-notif:/w -w /w swift:6.2-noble \
//     bash -c 'swiftc -swift-version 6 -default-isolation MainActor \
//                CCPresence.swift CCFaceMood.swift CCQuickReply.swift CCAskNotifyPolicy.swift main.swift -o t && ./t'

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

typealias N = CCAskNotifyPolicy
let t0 = Date(timeIntervalSinceReferenceDate: 0)
func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }

/// 一步：默认在后台、bot 在等。
func step(_ m: N.Memo, _ mood: CCFaceMood, wait: String = "要我继续吗？", replied: Date? = nil,
          active: Bool = false, _ now: TimeInterval) -> (memo: N.Memo, action: N.Action) {
    N.step(memo: m, mood: mood, wait: wait, repliedAt: replied, appActive: active, now: at(now))
}
/// 同上，脸是「等你」。（不用默认参数：末尾那个不带标签的时刻会被当成 mood。）
func step(_ m: N.Memo, wait: String = "要我继续吗？", replied: Date? = nil,
          active: Bool = false, _ now: TimeInterval) -> (memo: N.Memo, action: N.Action) {
    step(m, .waiting, wait: wait, replied: replied, active: active, now)
}

/// 跑一串（每 0.5 秒一份快照），数发了几次、撤了几次。
func run(_ seq: [(mood: CCFaceMood, wait: String, replied: Date?, active: Bool)], from: N.Memo = .empty)
    -> (posts: [String], removes: Int, memo: N.Memo) {
    var m = from, posts: [String] = [], removes = 0
    for (i, s) in seq.enumerated() {
        let r = N.step(memo: m, mood: s.mood, wait: s.wait, repliedAt: s.replied, appActive: s.active,
                       now: at(Double(i) * 0.5))
        m = r.memo
        switch r.action {
        case let .post(t): posts.append(t)
        case .remove: removes += 1
        case .none: break
        }
    }
    return (posts, removes, m)
}

func repeated(_ n: Int, _ mood: CCFaceMood = .waiting, _ wait: String = "要我继续吗？", replied: Date? = nil,
              active: Bool = false) -> [(mood: CCFaceMood, wait: String, replied: Date?, active: Bool)] {
    Array(repeating: (mood, wait, replied, active), count: n)
}

// MARK: - ① 边沿

let s1 = step(.empty, 0)
check("⭐ 后台、开始等你 ⇒ 发（去空白后的原句）", step(.empty, wait: "  要我继续吗？\n", 0).action == .post("要我继续吗？"))
check("发完记账：挂着、最近一次", s1.memo.posted == .init(text: "要我继续吗？", at: t0) && s1.memo.lastPost == s1.memo.posted
      && s1.memo.asking == "要我继续吗？")
check("同一句下一份快照 ⇒ 不再发", step(s1.memo, 0.5).action == .none)
check("⭐ 同一句挂 5 分钟（600 份快照）⇒ 只发 1 次", run(repeated(600)).posts.count == 1)
check("⭐ 过了 60 秒还挂着 ⇒ 不会自己再响", step(s1.memo, 61).action == .none)
let s2 = step(s1.memo, wait: "换个问题：选 A 还是 B？", 5)
check("⭐ 换了一句 ⇒ 发新的（同一个 id 顶掉旧的）", s2.action == .post("换个问题：选 A 还是 B？"))
check("换了一句 ⇒ 挂着的是新的", s2.memo.posted?.text == "换个问题：选 A 还是 B？")
check("没在等、wait 空 ⇒ 什么都不做", step(.empty, .idle, wait: "", 0).action == .none)
check("脸是等你但 wait 去空白后为空 ⇒ 不发", step(.empty, wait: "  \n ", 0).action == .none)

// MARK: - ② 前台

let f1 = step(.empty, active: true, 0)
check("⭐ 前台看着 ⇒ 不发", f1.action == .none)
check("⭐ 前台时出现的问题，切到后台后不补发", step(f1.memo, active: false, 10).action == .none)
check("前台时出现、切后台后换了一句 ⇒ 发新的", step(f1.memo, wait: "另一句", active: false, 10).action == .post("另一句"))
check("后台发了、回到前台、还在等 ⇒ 不重发也不撤", step(s1.memo, active: true, 3).action == .none)
check("前台时换了一句 ⇒ 不发、撤掉挂着的旧问题",
      step(s1.memo, wait: "新问题", active: true, 3).action == .remove
      && step(s1.memo, wait: "新问题", active: true, 3).memo.posted == nil)

// MARK: - ③ 断线 / 挂断 / bot 不在 / 按住说话

check("⭐ 找网络 ⇒ 不撤（wait 是残值）", step(s1.memo, .searching, 5).action == .none)
check("找网络 ⇒ 记账原样", step(s1.memo, .searching, 5).memo == s1.memo)
check("找网络时出现的残值 wait ⇒ 不发", step(.empty, .searching, 0).action == .none)
let blip = run(repeated(4) + repeated(20, .searching) + repeated(200))
check("⭐ 发了 → 重连 10 秒 → 回来还是那句（共 2 分钟）⇒ 只发 1 次、不撤", blip.posts.count == 1 && blip.removes == 0)
let hang = step(s1.memo, .asleep, 5)
check("⭐ 挂断（脸睡着）⇒ 撤", hang.action == .remove && hang.memo.posted == nil && hang.memo.asking == nil)
check("撤掉后再撤 ⇒ 什么都不做", step(hang.memo, .asleep, 6).action == .none)
check("bot 不在（derive 给睡着）⇒ 撤",
      step(s1.memo, CCFaceMood.derive(presence: .online, botPresent: false, wait: "要我继续吗？", on: false,
                                      holding: false, speaking: false, muted: false, finishedAt: nil, now: at(5)),
           5).action == .remove)
check("bot 回来还是那句、但已过 60 秒 ⇒ 再发（它被撤掉过）", step(hang.memo, 70).action == .post("要我继续吗？"))
check("bot 回来还是那句、60 秒内 ⇒ 不发", step(hang.memo, 30).action == .none)
check("bot 不问了（idle、wait 清空）⇒ 撤", step(s1.memo, .idle, wait: "", 4).action == .remove)
check("bot 开始干活（working）⇒ 撤", step(s1.memo, .working, wait: "", 4).action == .remove)
// ⑥ 跟快捷回复条同一个判据：拿真 derive 走
let holdingMood = CCFaceMood.derive(presence: .online, botPresent: true, wait: "要我继续吗？", on: false,
                                    holding: true, speaking: false, muted: false, finishedAt: nil, now: t0)
check("⭐ 按住说话（脸是在听）⇒ 不算在等、不发", holdingMood == .listening && step(.empty, holdingMood, 0).action == .none)
let offMood = CCFaceMood.derive(presence: .off, botPresent: true, wait: "要我继续吗？", on: false,
                                holding: false, speaking: false, muted: false, finishedAt: nil, now: t0)
check("没连上（残值 wait）⇒ 不发", step(.empty, offMood, 0).action == .none)
let speakMood = CCFaceMood.derive(presence: .online, botPresent: true, wait: "要我继续吗？", on: true,
                                  holding: false, speaking: true, muted: false, finishedAt: nil, now: t0)
check("在说话的同时举手 ⇒ 等你压过说话，照发", speakMood == .waiting && step(.empty, speakMood, 0).action == .post("要我继续吗？"))

// MARK: - ④ 回答过了

let r1 = step(s1.memo, replied: at(3), 3.5)
check("⭐ 发了之后回复过 ⇒ 撤", r1.action == .remove && r1.memo.posted == nil)
check("回复的同一刻也算（≥）", step(s1.memo, replied: t0, 0.5).action == .remove)
check("撤完 bot 还没清 wait ⇒ 不再发、不再撤", step(r1.memo, replied: at(3), 4).action == .none)
check("撤完 bot 清了 wait ⇒ 什么都不做", step(r1.memo, .working, wait: "", replied: at(3), 5).action == .none)
check("⭐ 上一个问题的回复（早于发出）撤不掉这一个", step(s1.memo, replied: at(-10), 1).action == .none)
let r2 = step(s1.memo, wait: "下一个问题", replied: at(1.9), 2)
check("回复后立刻来了新问题 ⇒ 发新的（同一 id 顶掉）", r2.action == .post("下一个问题") && r2.memo.posted?.text == "下一个问题")
check("新问题之后，那次旧回复撤不掉它", step(r2.memo, wait: "下一个问题", replied: at(1.9), 3).action == .none)
let ans = run(repeated(4) + repeated(10, replied: at(2)) + repeated(10, .working, "", replied: at(2)))
check("⭐ 端到端：问 → 点了回答 → bot 继续干活 ⇒ 发 1 次、撤 1 次", ans.posts.count == 1 && ans.removes == 1)
let again = run(repeated(4) + repeated(4, replied: at(1)) + repeated(4, .working, "", replied: at(1))
                + repeated(4, .waiting, "要我继续吗？", replied: at(1)))
check("回答撤掉之后，同一句 60 秒内又来 ⇒ 不再发（撤通知不清去重记录）", again.posts.count == 1 && again.removes == 1)

// MARK: - ⑤ 60 秒去重

check("去重窗口 = 60 秒（跟锁屏提醒同一个数）", N.repeatWindow == 60)
let mk = N.Mark(text: "A", at: t0)
check("同一句 59.9 秒 ⇒ 重复", N.isRepeat("A", last: mk, now: at(59.9)))
check("⭐ 同一句 60 秒整 ⇒ 不算重复（左闭右开）", !N.isRepeat("A", last: mk, now: at(60)))
check("同一句同一刻 ⇒ 重复（左闭）", N.isRepeat("A", last: mk, now: t0))
check("不同句 ⇒ 不重复", !N.isRepeat("B", last: mk, now: at(1)))
check("没发过 ⇒ 不重复", !N.isRepeat("A", last: nil, now: at(1)))
check("时钟往回拨 ⇒ 不算刚发过", !N.isRepeat("A", last: mk, now: at(-5)))
// 「等你 → 在听你说 → 等你」（按住说话又松开）在后台不太会有，但重连补发、bot 重发同一句会
let flap = run(repeated(4) + repeated(4, .idle, "") + repeated(4))
check("⭐ 等你 → 不等 → 同一句 2 秒后又来 ⇒ 只发 1 次（中间撤掉）", flap.posts.count == 1 && flap.removes == 1)
let flap2 = run(repeated(4) + repeated(4, .idle, "") + repeated(4, .waiting, "  要我继续吗？ "))
check("去重比较的是去空白后的原句", flap2.posts.count == 1)
let other = N.Memo(asking: nil, posted: nil, lastPost: .init(text: "要我继续吗？", at: t0))
check("去重分房间（各房间各一份记账；别的房间没发过就照发）", step(.empty, 1).action == .post("要我继续吗？")
      && step(other, 1).action == .none)

// MARK: - ⑦ 通知长什么样

check("每个房间一个固定 id", N.identifier(room: "jarvis") == "cc.ask.jarvis" && N.identifier(room: "bunny") != N.identifier(room: "jarvis"))
check("标题", N.title(room: "jarvis") == "jarvis 在等你")
check("正文去空白", N.body(wait: "  要我继续吗？\n") == "要我继续吗？")
let long = String(repeating: "问", count: 500)
check("正文按字符截到上限、末尾省略号", N.body(wait: long).count == N.bodyMax && N.body(wait: long).hasSuffix("…"))
check("正好上限 ⇒ 不截", N.body(wait: String(repeating: "问", count: N.bodyMax)) == String(repeating: "问", count: N.bodyMax))

let own = N.choices(options: ["用方案 A，先跑小规模", "用方案 B"], labels: ["方案 A", ""])
check("⭐ 带推荐答案 ⇒ 用 bot 的（跟主界面同一个函数）", own == CCQuickReply.choices(options: ["用方案 A，先跑小规模", "用方案 B"], labels: ["方案 A", ""]))
check("按钮上写短标签、缺了用原句", own.map(\.short) == ["方案 A", "用方案 B"])
check("⭐ 没带推荐 ⇒ 固定那两句", N.choices(options: nil, labels: nil) == CCQuickReply.choices
      && N.choices(options: ["  "], labels: nil) == CCQuickReply.choices)
check("最多 4 颗", N.choices(options: ["1", "2", "3", "4", "5", "6"], labels: nil).count == 4)

check("action id 往返", (0..<4).allSatisfy { N.index(fromActionID: N.actionID(index: $0)) == $0 })
check("系统的默认点击 / 划掉 ⇒ 不是回答", N.index(fromActionID: "com.apple.UNNotificationDefaultActionIdentifier") == nil
      && N.index(fromActionID: "com.apple.UNNotificationDismissActionIdentifier") == nil)
check("坏 id ⇒ nil", N.index(fromActionID: "cc.ask.reply.") == nil && N.index(fromActionID: "cc.ask.reply.x") == nil
      && N.index(fromActionID: "cc.ask.reply.-1") == nil)

let info = N.userInfo(room: "jarvis", choices: own) as [AnyHashable: Any]
check("⭐ 点第 1 颗 ⇒ 给 jarvis 发完整原句（不是短标签）",
      N.reply(userInfo: info, actionID: N.actionID(index: 0)).map { $0.room == "jarvis" && $0.text == "用方案 A，先跑小规模" } == true)
check("点第 2 颗", N.reply(userInfo: info, actionID: N.actionID(index: 1))?.text == "用方案 B")
check("下标越界 ⇒ nil（不发错句）", N.reply(userInfo: info, actionID: N.actionID(index: 2)) == nil)
check("点通知本身 ⇒ 不是回答，但知道是哪个房间", N.reply(userInfo: info, actionID: "com.apple.UNNotificationDefaultActionIdentifier") == nil
      && N.tappedRoom(userInfo: info) == "jarvis")
check("userInfo 缺房间 / 缺句子 ⇒ nil", N.reply(userInfo: [N.textsKey: ["a"]], actionID: N.actionID(index: 0)) == nil
      && N.reply(userInfo: [N.roomKey: "x"], actionID: N.actionID(index: 0)) == nil
      && N.reply(userInfo: [N.roomKey: "", N.textsKey: ["a"]], actionID: N.actionID(index: 0)) == nil)
check("别人的通知（没有房间）⇒ 不切房间", N.tappedRoom(userInfo: ["aps": 1]) == nil)
// userInfo 必须能进 plist（UNNotificationContent 要求）
check("userInfo 能序列化成 plist", (try? PropertyListSerialization.data(fromPropertyList: N.userInfo(room: "r", choices: own),
                                                                       format: .binary, options: 0)) != nil)

let fixed = N.categoryID(choices: CCQuickReply.choices)
// 期望值是用 Python 独立算的 FNV-1a（不是从这份实现里抄出来的）。
check("⭐ category id：同一组按钮 ⇒ 同一个（跨进程稳定，不用随机加盐的 Hasher）",
      fixed == N.categoryID(choices: N.choices(options: nil, labels: nil)) && fixed == "cc.ask.cat.e8d23b75d2fe2ffb")
check("换一组按钮 ⇒ 换 id", N.categoryID(choices: own) != fixed)
check("只换短标签 ⇒ 换 id（按钮上的字跟着 category 走）",
      N.categoryID(choices: N.choices(options: ["用方案 A，先跑小规模", "用方案 B"], labels: ["A", ""])) != N.categoryID(choices: own))
check("只换发出去的句子 ⇒ 换 id（同一个按钮发不同的句子，userInfo 管句子，但别共用陈旧 category）",
      N.categoryID(choices: [.init(text: "x1", short: "X", symbol: "")]) != N.categoryID(choices: [.init(text: "x2", short: "X", symbol: "")]))
check("⭐ 字段边界不撞（ab|c vs a|bc）",
      N.categoryID(choices: [.init(text: "c", short: "ab", symbol: "")]) != N.categoryID(choices: [.init(text: "bc", short: "a", symbol: "")]))
check("顺序不同 ⇒ 不同 id（下标对应 action）",
      N.categoryID(choices: own) != N.categoryID(choices: own.reversed()))
check("category id 带前缀", fixed.hasPrefix("cc.ask.cat."))

// MARK: - 从 nonisolated 上下文可用（通知 delegate 回调是 nonisolated 的）

// 漏标 nonisolated 的话，这个函数编不过（见 Tests/README.md 那节「默认隔离开着时」）。
nonisolated func touchFromNonisolated() -> Int {
    let r = N.reply(userInfo: [N.roomKey: "x", N.textsKey: ["a"]], actionID: N.actionID(index: 0))
    let s = N.step(memo: .empty, mood: .waiting, wait: "q", repliedAt: nil, appActive: false, now: Date())
    return (r?.text.count ?? 0) + (N.tappedRoom(userInfo: [:]) == nil ? 1 : 0) + (s.action == .post("q") ? 1 : 0)
        + N.identifier(room: "x").count + N.categoryID(choices: N.choices(options: nil, labels: nil)).count
}
check("规则能从 nonisolated 上下文用（编译过就算过）", touchFromNonisolated() > 0)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
