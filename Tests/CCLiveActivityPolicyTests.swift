// 锁屏实时活动的规则测试（`CCLiveActivityPolicy` ＋ 卡片数据 `CCLiveActivityState`）。
//
// 要钉住的是几条「写错了日常也看不出来」的：
//   ① 断线重连期间卡片**不关**（判据是用户想连着，不是此刻连着）；挂断才关；
//   ② 用户划掉卡片 ⇒ 这一轮不再开；系统 8 小时收走 / 关掉系统开关 ⇒ 不算划掉；
//   ③ 节流是「至少隔 1 秒」而不是「丢掉 1 秒内的变化」—— 最后一份一定会推出去；
//   ④ 状态不变也要在过期前续一次（否则安静闲着半小时卡片就变「已断开」）；
//   ⑤ 断线时状态行、子任务数不用 bot 状态的残值（跟活脸同一条规矩）；
//   ⑥ 认不出的心情字符串不能让整份卡片解码失败（新 app ＋ 旧扩展）。
//
// 跑法见 Tests/README.md：
//
//   mkdir -p /tmp/swtest && cd VoiceAgent/CloseCrab && cp CCPresence.swift CCFaceMood.swift \
//     CCFaceMotion.swift CCFaceGrokEyes.swift CCLiveActivityState.swift CCLiveActivityPolicy.swift /tmp/swtest/
//   cp Tests/CCLiveActivityPolicyTests.swift /tmp/swtest/main.swift
//   docker run --rm -v /tmp/swtest:/w -w /w swift:6.2-noble \
//     bash -c 'swiftc -swift-version 6 -default-isolation MainActor \
//                CCPresence.swift CCFaceMood.swift CCFaceMotion.swift CCFaceGrokEyes.swift \
//                CCLiveActivityState.swift CCLiveActivityPolicy.swift main.swift -o t && ./t'

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

typealias P = CCLiveActivityPolicy
typealias S = CCLiveActivityState

// 零点取参考时刻本身：`Date` 是 Double 秒，零点取个 8 亿秒的「真实」时刻的话，
// 0.3 秒这种小数会被吃掉末几位（0.29999995），等式断言就成了在测浮点误差。
let t0 = Date(timeIntervalSinceReferenceDate: 0)
func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }

func life(enabled: Bool = true, want: Bool = true, room: String = "bunny", hasCard: Bool = false,
          startedAt: Date? = nil, dismissed: Bool = false, now: Date = t0) -> P.Lifecycle {
    P.lifecycle(enabled: enabled, wantConnected: want, room: room, hasCard: hasCard,
                cardStartedAt: startedAt, dismissedByUser: dismissed, now: now)
}

// MARK: - 开 / 关 / 换

check("⭐ 按了开始、还没卡 ⇒ 开", life() == .start)
check("⭐ 挂断（不想连了）⇒ 有卡就关", life(want: false, hasCard: true, startedAt: t0) == .end)
check("挂断、本来就没卡 ⇒ 什么都不做", life(want: false) == .none)
// ① 断线重连：wantConnected 仍为真 ⇒ 卡片照旧（这里的 Policy 根本不看连接相位 —— 对的）
check("⭐ 断线重连期间（想连着）有卡 ⇒ 继续用，不关", life(hasCard: true, startedAt: t0, now: at(60)) == .keep)
check("还没选房间 ⇒ 不开", life(room: "") == .none)
check("房间名变空 ⇒ 关", life(room: "", hasCard: true, startedAt: t0) == .end)
check("系统开关关着 ⇒ 不开", life(enabled: false) == .none)
check("系统开关被关掉 ⇒ 有卡就关", life(enabled: false, hasCard: true, startedAt: t0) == .end)
check("⭐ 用户划掉过 ⇒ 不再开", life(dismissed: true) == .none)
check("用户划掉过、手上还记着卡 ⇒ 关", life(hasCard: true, startedAt: t0, dismissed: true) == .end)

// 换卡边界：7.5 小时整（含）换，差 1 秒不换
let roll = P.rolloverAfter
check("差 1 秒到换卡时刻 ⇒ 继续用", life(hasCard: true, startedAt: t0, now: at(roll - 1)) == .keep)
check("⭐ 正好到换卡时刻 ⇒ 换", life(hasCard: true, startedAt: t0, now: at(roll)) == .rollover)
check("超过换卡时刻 ⇒ 换", life(hasCard: true, startedAt: t0, now: at(roll + 3600)) == .rollover)
check("没卡时不谈换卡（开新的）", life(hasCard: false, startedAt: t0, now: at(roll + 1)) == .start)
check("开卡时刻未知 ⇒ 不换（继续用）", life(hasCard: true, startedAt: nil, now: at(roll * 2)) == .keep)
check("不想连了即使到点 ⇒ 关不换", life(want: false, hasCard: true, startedAt: t0, now: at(roll)) == .end)

// 换卡时刻要求的是区间，不是某个值：留出余量（< 8 小时系统上限）、又别换得太勤（≥ 7 小时）
check("换卡时刻早于系统 8 小时上限", P.rolloverAfter < P.systemMaxAge)
check("换卡不能太勤（≥ 7 小时）", P.rolloverAfter >= 7 * 3600)
check("系统上限就是 8 小时", P.systemMaxAge == 8 * 3600)

// 全组合：想要卡 ⇔ enabled && want && 有房间 && 没划掉；结果只能在 {start, keep, rollover} ↔ 想要，{end, none} ↔ 不想要
var combos = 0
for enabled in [false, true] {
    for want in [false, true] {
        for room in ["", "bunny"] {
            for hasCard in [false, true] {
                for dismissed in [false, true] {
                    for age in [0.0, roll] {
                        combos += 1
                        let r = life(enabled: enabled, want: want, room: room, hasCard: hasCard,
                                     startedAt: t0, dismissed: dismissed, now: at(age))
                        let wantCard = enabled && want && !room.isEmpty && !dismissed
                        let expect: P.Lifecycle = !wantCard ? (hasCard ? .end : .none)
                            : (!hasCard ? .start : (age >= roll ? .rollover : .keep))
                        check("组合 enabled=\(enabled) want=\(want) room=\(room) card=\(hasCard) dismissed=\(dismissed) age=\(age)",
                              r == expect, "\(r) ≠ \(expect)")
                    }
                }
            }
        }
    }
}
check("组合数 64", combos == 64)

// MARK: - 开卡失败后的重试

check("没失败过 ⇒ 试", P.shouldRetryStart(lastFailure: nil, now: t0))
check("刚失败 ⇒ 不试", !P.shouldRetryStart(lastFailure: t0, now: at(1)))
check("差 1 秒到重试间隔 ⇒ 不试", !P.shouldRetryStart(lastFailure: t0, now: at(P.startRetry - 1)))
check("正好到重试间隔 ⇒ 试", P.shouldRetryStart(lastFailure: t0, now: at(P.startRetry)))
check("⭐ 时钟往回拨 ⇒ 试（别卡在未来时刻）", P.shouldRetryStart(lastFailure: at(100), now: t0))
check("重试间隔是分钟级（1…15 分钟）", P.startRetry >= 60 && P.startRetry <= 15 * 60)

// MARK: - 卡片没了：算不算用户划掉

check("⭐ 开着开关、没到 8 小时就没了 ⇒ 用户划掉", P.goneMeansUserDismissed(age: 60, enabled: true))
check("差 1 秒到 8 小时 ⇒ 仍算划掉", P.goneMeansUserDismissed(age: P.systemMaxAge - 1, enabled: true))
check("⭐ 到了 8 小时 ⇒ 系统收走，不算", !P.goneMeansUserDismissed(age: P.systemMaxAge, enabled: true))
check("⭐ 开关关着 ⇒ 不算划掉（打开后该立刻回来）", !P.goneMeansUserDismissed(age: 60, enabled: false))

// MARK: - 推不推

check("从没推过 ⇒ 现在推", P.push(next: 1, last: nil as Int?, lastPushAt: nil, now: t0) == .now)
check("有上一份但不知道何时推的 ⇒ 现在推", P.push(next: 1, last: 1, lastPushAt: nil, now: t0) == .now)
check("没变、刚推过 ⇒ 不推", P.push(next: 1, last: 1, lastPushAt: t0, now: at(5)) == .skip)
check("没变、差 1 秒到续期 ⇒ 不推", P.push(next: 1, last: 1, lastPushAt: t0, now: at(P.keepAliveAfter - 1)) == .skip)
check("⭐ 没变、到了续期 ⇒ 推（续过期时间）", P.push(next: 1, last: 1, lastPushAt: t0, now: at(P.keepAliveAfter)) == .now)
check("变了、刚过窗口 ⇒ 推", P.push(next: 2, last: 1, lastPushAt: t0, now: at(P.minUpdateInterval)) == .now)
check("⭐ 变了、窗口没到 ⇒ 等到窗口满（不是丢掉）",
      P.push(next: 2, last: 1, lastPushAt: t0, now: at(0.3)) == .wait(P.minUpdateInterval - 0.3))
check("变了、同一时刻 ⇒ 等满整个窗口",
      P.push(next: 2, last: 1, lastPushAt: t0, now: t0) == .wait(P.minUpdateInterval))
check("时钟往回拨、变了 ⇒ 推（别算出一个超长等待）", P.push(next: 2, last: 1, lastPushAt: at(100), now: t0) == .now)
check("时钟往回拨、没变 ⇒ 不推", P.push(next: 1, last: 1, lastPushAt: at(100), now: t0) == .skip)

// 区间要求（钉需求不钉值）
check("⭐ 节流至少 1 秒（Chris 定的）", P.minUpdateInterval >= 1)
check("节流不超过 5 秒（锁屏上反应不能太钝）", P.minUpdateInterval <= 5)
check("过期时间 15 分钟（方案定的）", P.staleAfter == 15 * 60)
check("⭐ 续期间隔必须短于过期时间", P.keepAliveAfter < P.staleAfter)
check("续期不能太勤（≥ 1 分钟）", P.keepAliveAfter >= 60)
check("到点容差：大于 0（防打转）、小于 50 毫秒（不能把节流吃掉）", P.timingSlack > 0 && P.timingSlack < 0.05)
check("⭐ 醒来差一丁点（浮点舍入）⇒ 算到点，不再定一个更小的闹钟",
      P.push(next: 2, last: 1, lastPushAt: t0, now: at(P.minUpdateInterval - 1e-9)) == .now)
check("差得多（0.1 秒）⇒ 还是要等", P.push(next: 2, last: 1, lastPushAt: t0, now: at(P.minUpdateInterval - 0.1)) != .now)
// 大零点（真实时刻量级）下也不打转：800,000,000 秒 + 小数，Double 会吃掉末几位
let big = Date(timeIntervalSinceReferenceDate: 800_000_000.123)
check("真实时刻量级下醒来再算 ⇒ 推",
      P.push(next: 2, last: 1, lastPushAt: big,
             now: big.addingTimeInterval(0.3).addingTimeInterval(P.minUpdateInterval - 0.3)) == .now)
check("过期时间 = now + staleAfter", P.staleDate(now: t0) == at(P.staleAfter))

// ③ 模拟：一串乱序到来的变化，按「立刻推 / 等到点再算」驱动，检查两件事 ——
//    任意两次推之间 ≥ 窗口；最后一份一定被推出去（不会停在中间态）。
func simulate(_ changes: [(TimeInterval, Int)]) -> (pushes: [(TimeInterval, Int)], final: Int?) {
    var state = 0
    var lastPushed: Int?
    var lastAt: Date?
    var pushes: [(TimeInterval, Int)] = []
    var wake: TimeInterval?
    var events = changes.sorted { $0.0 < $1.0 }
    func run(_ now: TimeInterval) {
        switch P.push(next: state, last: lastPushed, lastPushAt: lastAt, now: at(now)) {
        case .skip: break
        case .now:
            lastPushed = state; lastAt = at(now); pushes.append((now, state))
        case let .wait(dt):
            let w = now + dt
            if wake == nil || w < wake! { wake = w }
        }
    }
    var steps = 0
    while !events.isEmpty || wake != nil {
        // 防原地打转：规则写坏时（比如容差没了）这里会死循环，测试台不能跟着挂死。
        steps += 1
        if steps > 100_000 { return (pushes, nil) }
        if let w = wake, events.isEmpty || w <= events[0].0 {
            wake = nil
            run(w)
        } else {
            let (t, v) = events.removeFirst()
            state = v
            run(t)
        }
    }
    return (pushes, lastPushed)
}

var rng = UInt64(0x9E37_79B9_7F4A_7C15)
func rnd() -> Double {
    rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Double(rng >> 11) / Double(1 << 53)
}
var simOK = true, gapOK = true
for trial in 0..<300 {
    var t = 0.0
    var changes: [(TimeInterval, Int)] = []
    for k in 0..<Int(5 + rnd() * 40) {
        t += rnd() < 0.7 ? rnd() * 0.4 : rnd() * 3   // 多数挤在一个窗口里，偶尔隔开
        changes.append((t, k + 1 + trial * 1000))
    }
    let r = simulate(changes)
    if r.final != changes.last!.1 { simOK = false }
    for i in 1..<max(1, r.pushes.count) where r.pushes[i].0 - r.pushes[i - 1].0 < P.minUpdateInterval - P.timingSlack - 1e-9 {
        gapOK = false
    }
}
check("⭐ 300 串随机变化：最后一份一定推出去", simOK)
check("⭐ 300 串随机变化：任意两次推之间 ≥ 节流窗口（减到点容差）", gapOK)
let burst = simulate([(0, 1), (0.1, 2), (0.2, 3), (0.9, 4)])
check("一阵连发：第一份立刻推、最后一份在窗口到点推，中间的合并掉",
      burst.pushes.map(\.1) == [1, 4] && abs(burst.pushes[1].0 - P.minUpdateInterval) < 1e-9,
      "\(burst.pushes)")

// MARK: - 时间相关心情的重算时刻

let dw = CCFaceMood.doneWindow, sh = CCFaceMood.speakingHold
check("刚干完窗口里 ⇒ 到窗口末尾重算", P.nextRecheck(now: at(1), finishedAt: t0, speechEndedAt: nil) == at(dw))
check("刚干完窗口外 ⇒ 不用重算", P.nextRecheck(now: at(dw), finishedAt: t0, speechEndedAt: nil) == nil)
check("说话宽限里 ⇒ 到宽限末尾重算", P.nextRecheck(now: at(0.5), finishedAt: nil, speechEndedAt: t0) == at(sh))
check("说话宽限外 ⇒ 不用重算", P.nextRecheck(now: at(sh), finishedAt: nil, speechEndedAt: t0) == nil)
check("两个都在窗口里 ⇒ 取早的那个", P.nextRecheck(now: at(1), finishedAt: t0, speechEndedAt: at(0.8)) == at(min(dw, 0.8 + sh)))
check("两个都在、说话那个更晚 ⇒ 仍取早的", P.nextRecheck(now: at(2.5), finishedAt: t0, speechEndedAt: at(2.4)) == at(dw))
check("时间倒退不算在窗口里", P.nextRecheck(now: t0, finishedAt: at(10), speechEndedAt: at(10)) == nil)
check("都没有 ⇒ nil", P.nextRecheck(now: t0, finishedAt: nil, speechEndedAt: nil) == nil)

// MARK: - 计时起点

check("在跑一轮 ⇒ now − sec", P.timerStart(on: true, sec: 30, now: at(100), previous: nil, moodSince: t0) == at(70))
check("没在跑 ⇒ 进入当前心情的时刻", P.timerStart(on: false, sec: 30, now: at(100), previous: nil, moodSince: at(5)) == at(5))
check("⭐ 抖动在容忍内 ⇒ 沿用上一次（不白推）",
      P.timerStart(on: true, sec: 30.4, now: at(100), previous: at(70), moodSince: t0) == at(70))
check("正好在容忍边界 ⇒ 沿用",
      P.timerStart(on: true, sec: 30 + P.timerTolerance, now: at(100), previous: at(70), moodSince: t0) == at(70))
check("超出容忍 ⇒ 换新起点（新的一轮）",
      P.timerStart(on: true, sec: 5, now: at(100), previous: at(70), moodSince: t0) == at(95))
check("sec 为负按 0 算", P.timerStart(on: true, sec: -3, now: at(100), previous: nil, moodSince: t0) == at(100))
check("容忍在半秒到 5 秒之间（大于服务端限频抖动、小于肉眼能看出的跳）",
      P.timerTolerance >= 0.5 && P.timerTolerance <= 5)

// MARK: - 状态行

check("⭐ 睡着时不用残值", P.headline(mood: .asleep, snapHeadline: "在读文件") == CCFaceMood.asleep.spoken)
check("⭐ 找网络时不用残值", P.headline(mood: .searching, snapHeadline: "在读文件") == CCFaceMood.searching.spoken)
check("在查东西 ⇒ 用 bot 状态那句", P.headline(mood: .working, snapHeadline: "跑 Q10 验收") == "跑 Q10 验收")
check("等你 ⇒ 用 bot 状态那句", P.headline(mood: .waiting, snapHeadline: "要批准 rm -rf？") == "要批准 rm -rf？")
check("没收到过状态 ⇒ 用脸的说法", P.headline(mood: .idle, snapHeadline: nil) == CCFaceMood.idle.spoken)
check("状态是空白 ⇒ 用脸的说法", P.headline(mood: .working, snapHeadline: "  \n ") == CCFaceMood.working.spoken)
check("首尾空白去掉", P.headline(mood: .working, snapHeadline: "  读文件 \n") == "读文件")
let long = String(repeating: "查", count: 200)
let h = P.headline(mood: .working, snapHeadline: long)
check("⭐ 太长截到上限", h.count == P.headlineMax && h.hasSuffix("…"), "\(h.count)")
check("截断按字符：emoji 不被劈开", P.truncate("👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦", max: 2) == "👩‍👩‍👧‍👦…")
check("正好等于上限不截", P.truncate(String(repeating: "a", count: 80), max: 80).count == 80
      && !P.truncate(String(repeating: "a", count: 80), max: 80).hasSuffix("…"))
check("超 1 个字符 ⇒ 截成上限长度且带省略号", P.truncate(String(repeating: "a", count: 81), max: 80) == String(repeating: "a", count: 79) + "…")
check("上限 0 ⇒ 空串", P.truncate("abc", max: 0) == "")
check("上限 1 ⇒ 只剩省略号", P.truncate("abc", max: 1) == "…")

// MARK: - 拼卡片

func mk(mood: CCFaceMood = .working, skin: CCFaceSkin? = .bunny, subs: Int = 3,
        active: Bool = false, paused: Bool = false, replay: Bool = false,
        peers: [(name: String, dot: CCPresenceDot)] = []) -> S {
    P.makeState(room: "bunny", mood: mood, skin: skin, presence: .online, snapHeadline: "跑 Q10 验收",
                runningSubtasks: subs, timerStart: t0, isActive: active, isPaused: paused, canReplay: replay,
                peers: peers)
}
check("字段原样落进去", mk().room == "bunny" && mk().mood == "working" && mk().skin == "bunny"
      && mk().presence == "online" && mk().headline == "跑 Q10 验收" && mk().subtasks == 3 && mk().timerStart == t0)
check("⭐ 没选活脸 ⇒ classic（卡片上总得有张脸）", mk(skin: nil).skin == CCFaceSkin.classic.rawValue)
check("⭐ 断线时子任务数不显示（残值）", mk(mood: .searching).subtasks == 0 && mk(mood: .asleep).subtasks == 0)
check("子任务数为负按 0", mk(subs: -2).subtasks == 0)
check("在播", mk(active: true, paused: false).isPlaying && !mk(active: true, paused: false).isPaused)
check("暂停", !mk(active: true, paused: true).isPlaying && mk(active: true, paused: true).isPaused)
check("没东西 ⇒ 既不在播也不算暂停", !mk(active: false, paused: false).isPlaying && !mk(active: false, paused: false).isPaused)
check("⭐ 不活跃时服务端的 paused 残值不算暂停", !mk(active: false, paused: true).isPaused && !mk(active: false, paused: true).isPlaying)
check("能重播原样带上", mk(replay: true).canReplay && !mk(replay: false).canReplay)
let many: [(name: String, dot: CCPresenceDot)] =
    [("bunny", .online), ("jarvis", .online), ("tommy", .degraded), ("a", .off), ("b", .retrying), ("c", .connecting), ("d", .online)]
let ps = mk(peers: many).peers
check("⭐ 当前房间不出现在小圆点里", !ps.contains { $0.name == "bunny" })
check("小圆点封顶", ps.count == P.maxPeers, "\(ps.count)")
check("小圆点保留传入顺序", ps.map(\.name) == ["jarvis", "tommy", "a", "b", "c"])
check("小圆点颜色原样", ps[1].dot == "degraded")

// MARK: - 卡片数据本身

let base = mk(active: true, replay: true, peers: Array(many.prefix(3)))
let st = base.staleVersion
check("⭐ 过期版：睡着、灰点、已断开、不在播", st.faceMood == .asleep && st.dot == .off && st.headline == "已断开"
      && !st.isPlaying && !st.isPaused && st.subtasks == 0)
check("过期版保留房间名和其他房间", st.room == base.room && st.peers == base.peers)
check("状态行带子任务数", mk(subs: 3).statusLine == "跑 Q10 验收（3 个子任务）")
check("没子任务不带括号", mk(subs: 0).statusLine == "跑 Q10 验收")
var odd = base
odd.mood = "future_mood"; odd.skin = "dragon"; odd.presence = "purple"
check("认不出的心情 ⇒ 空闲", odd.faceMood == .idle)
check("认不出的皮肤 ⇒ classic", odd.faceSkin == .classic)
check("认不出的小圆点 ⇒ 灰", odd.dot == .off)

let enc = JSONEncoder()
let data = try! enc.encode(base)
check("编解码往返无损", (try? JSONDecoder().decode(S.self, from: data)) == base)
// ⑥ 新 app 发了一个旧扩展不认识的心情：整份解码不能失败
var json = String(data: data, encoding: .utf8)!
json = json.replacingOccurrences(of: "\"working\"", with: "\"some_new_mood\"")
let decoded = try? JSONDecoder().decode(S.self, from: json.data(using: .utf8)!)
check("⭐ 不认识的心情字符串照样解码成功", decoded != nil)
check("…并且画成空闲", decoded?.faceMood == .idle)

// 体积：最坏情况（状态行截满 80 个汉字、5 个长名字房间）离 ActivityKit 的 4 KB 很远
let fat = P.makeState(room: String(repeating: "r", count: 32), mood: .waiting, skin: .grok, presence: .degraded,
                      snapHeadline: String(repeating: "等", count: 500), runningSubtasks: 99, timerStart: t0,
                      isActive: true, isPaused: true, canReplay: true,
                      peers: (0..<9).map { (name: String(repeating: "\($0)", count: 32), dot: CCPresenceDot.retrying) })
let fatBytes = try! enc.encode(fat).count
check("⭐ 最坏情况编码后 < 2 KB（上限 4 KB 留一半余量）", fatBytes < 2048, "\(fatBytes) 字节")

// MARK: - 小圆点颜色（app 和扩展共用一份）

let allDots: [CCPresenceDot] = [.off, .retrying, .connecting, .degraded, .online]
check("五种颜色互不相同", Set(allDots.map(\.signalHex)).count == 5)
check("颜色跟原 CCPresenceDotView 逐个一致",
      allDots.map(\.signalHex) == [0x9AA0A6, 0xD93025, 0xF9AB00, 0xE37400, 0x1E8E3E])

// MARK: - 从 nonisolated 上下文读（编译过就算过）
//
// ActivityKit 在自己的线程上编解码 ContentState；扩展的视图、app 的管理器也会读这些。
// 漏标 nonisolated 的话，这个函数编不过（见 Tests/README.md 那节「默认隔离开着时」）。
nonisolated func touchFromNonisolated() -> Int {
    let s = P.makeState(room: "x", mood: .idle, skin: nil, presence: .off, snapHeadline: nil, runningSubtasks: 0,
                        timerStart: Date(), isActive: false, isPaused: false, canReplay: false, peers: [])
    let d = (try? JSONEncoder().encode(s.staleVersion))?.count ?? 0
    _ = P.push(next: 1, last: 2, lastPushAt: nil, now: Date())
    _ = P.lifecycle(enabled: true, wantConnected: true, room: "x", hasCard: false, cardStartedAt: nil,
                    dismissedByUser: false, now: Date())
    return d + s.statusLine.count + s.faceMood.rawValue.count + Int(s.dot.signalHex & 1)
}
check("卡片数据和规则能从 nonisolated 上下文用（编译过就算过）", touchFromNonisolated() > 0)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
