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
check("⭐ 在说话 ⇒ 写「在说话」，不用 bot 状态那句「空闲」",
      P.headline(mood: .speaking, snapHeadline: "空闲") == CCFaceMood.speaking.spoken)
check("⭐ 在听你说 ⇒ 用脸的说法", P.headline(mood: .listening, snapHeadline: "空闲") == CCFaceMood.listening.spoken)
check("空闲 ⇒ 用脸的说法（不吃残留的旧动作）", P.headline(mood: .idle, snapHeadline: "在读文件") == CCFaceMood.idle.spoken)
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

// MARK: - 语音播放进度（2026-10-05）
//
// 要钉的需求：
//   ⑦ 在播时卡片**自己走**，app 不每秒推 —— 服务端每秒报一次、每次都带几百毫秒抖动，
//      只有开始 / 暂停 / 继续 / 换段 / 总长未知→已知 / 总长变 >1 s / 偏差 >2 s 才推；
//   ⑧ 总长未知（还在生成）**不画进度条**（不编分母）；
//   ⑨ 新扩展读旧 app 推的卡（没这几个键）、旧扩展读新 app 推的卡，都不能整份解码失败。

typealias M = P.PlayMark

func mark(active: Bool = true, paused: Bool = false, played: Double = 0, total: Double? = 48,
          fid: String = "f1", prev: M? = nil, now: Date = t0) -> M {
    P.playMark(isActive: active, isPaused: paused, played: played, total: total, fid: fid, previous: prev, now: now)
}

check("⭐ 没东西（不活跃、没 fid）⇒ none", mark(active: false, fid: "") == .none)
check("没东西时不管上一份", mark(active: false, fid: "", prev: mark(played: 3)) == .none)
let m0 = mark(played: 12, now: at(100))
check("⭐ 在播：起点 ＝ 现在 − 已播", m0.start == at(88) && m0.played == nil && m0.total == 48 && m0.fid == "f1")
check("第一份（没有上一份）一定给新值", m0.isPlaying)

// ⑦ 每秒一次、服务端如实前进 ⇒ 一直沿用
check("⭐ 1 秒后已播 +1 ⇒ 沿用（不推）", mark(played: 13, prev: m0, now: at(101)) == m0)
check("抖 0.3 秒 ⇒ 沿用", mark(played: 13.3, prev: m0, now: at(101)) == m0)
check("抖 −0.4 秒 ⇒ 沿用", mark(played: 12.6, prev: m0, now: at(101)) == m0)
// 偏差边界：2 秒（含）沿用，过一点就换
check("⭐ 偏差正好 2 秒 ⇒ 沿用", mark(played: 15, prev: m0, now: at(101)) == m0)
check("⭐ 偏差 2.01 秒 ⇒ 换新起点", mark(played: 15.01, prev: m0, now: at(101)).start == at(101 - 15.01))
check("落后 2.01 秒 ⇒ 换新起点（卡住等生成也要跟上）", mark(played: 12, prev: m0, now: at(102.01)) != m0)
check("落后正好 2 秒 ⇒ 沿用", mark(played: 12, prev: m0, now: at(102)) == m0)
check("容忍区间是需求不是巧合：≥ 1 秒（吃掉 RPC 抖动）且 ≤ 5 秒（偏了别太久没人管）",
      P.playDriftTolerance >= 1 && P.playDriftTolerance <= 5)

// 开始 / 暂停 / 继续 / 播完 / 换段
let mp = mark(paused: true, played: 20, prev: m0, now: at(108))
check("⭐ 暂停 ⇒ 换新值：没有起点、停在 20 秒", mp != m0 && mp.start == nil && mp.played == 20 && mp.total == 48)
check("暂停中再报一次同样的秒数 ⇒ 沿用", mark(paused: true, played: 20, prev: mp, now: at(120)) == mp)
check("暂停中秒数有小数抖动但显示的整秒不变 ⇒ 沿用", mark(paused: true, played: 20.4, prev: mp, now: at(121)) == mp)
check("⭐ 暂停中拖了一下（显示的整秒变了）⇒ 换", mark(paused: true, played: 27, prev: mp, now: at(122)).played == 27)
check("暂停中变到下一个整秒 ⇒ 换", mark(paused: true, played: 20.6, prev: mp, now: at(122)) != mp)
let mr = mark(played: 20, prev: mp, now: at(130))
check("⭐ 继续 ⇒ 换新值：起点按现在重算", mr.start == at(110) && mr.played == nil)
let mf = mark(active: false, played: 48, prev: mr, now: at(138))
check("⭐ 播完（不活跃、fid 还在）⇒ 停在末尾，还算有东西", mf.start == nil && mf.played == 48 && mf.fid == "f1")
check("播完之后反复轮询 ⇒ 沿用", mark(active: false, played: 48, prev: mf, now: at(142)) == mf)
check("⭐ 不活跃时服务端 paused 的残值不算在播", mark(active: false, paused: false, played: 5).start == nil)
let mn = mark(played: 0.5, fid: "f2", prev: m0, now: at(101))
check("⭐ 换了一段（fid 变）⇒ 换新值，哪怕起点碰巧很近", mn.fid == "f2" && mn != m0)
check("换段但起点几乎一样也换", mark(played: 13, fid: "f2", prev: m0, now: at(101)).fid == "f2")
check("⭐ 重播同一段（played 回到 0）⇒ 换", mark(played: 0, prev: m0, now: at(101)).start == at(101))

// 总长
let mu = mark(played: 3, total: nil, now: at(10))
check("总长未知 ⇒ total 为 nil", mu.total == nil && mu.start == at(7))
check("未知时照样沿用", mark(played: 4, total: nil, prev: mu, now: at(11)) == mu)
check("⭐ 总长从未知变已知 ⇒ 换", mark(played: 4, total: 30, prev: mu, now: at(11)).total == 30)
check("总长从已知变未知 ⇒ 换", mark(played: 13, total: nil, prev: m0, now: at(101)).total == nil)
check("总长变 0.9 秒 ⇒ 沿用（保留上一份总长）", mark(played: 13, total: 48.9, prev: m0, now: at(101)) == m0)
check("⭐ 总长变正好 1 秒 ⇒ 沿用", mark(played: 13, total: 49, prev: m0, now: at(101)) == m0)
check("⭐ 总长变 1.01 秒 ⇒ 换", mark(played: 13, total: 49.01, prev: m0, now: at(101)).total == 49.01)
check("总长变小 1.5 秒 ⇒ 换", mark(played: 13, total: 46.5, prev: m0, now: at(101)) != m0)
check("总长 0 / 负数 / NaN / 无穷 ⇒ 当未知",
      [0.0, -3, .nan, .infinity].allSatisfy { mark(played: 1, total: $0).total == nil })
check("已播为负 ⇒ 按 0（起点不能在将来）", mark(played: -5, now: at(10)).start == at(10))
check("已播 NaN ⇒ 按 0", mark(played: .nan, now: at(10)).start == at(10))
check("totalsClose 一个已知一个未知 ⇒ 不一样", !P.totalsClose(nil, 3) && !P.totalsClose(3, nil))

// 拼卡片 ＋ 怎么画
func pst(active: Bool, paused: Bool = false, replay: Bool = true, play: M) -> S {
    P.makeState(room: "bunny", mood: .speaking, skin: .bunny, presence: .online, snapHeadline: "在说话",
                runningSubtasks: 0, timerStart: t0, isActive: active, isPaused: paused, canReplay: replay,
                peers: [], play: play)
}
let sRun = pst(active: true, play: m0)
check("⭐ 在播、总长已知 ⇒ 从起点走到起点＋总长", sRun.playDisplay == .running(at(88)...at(136)))
check("在播时卡片不带暂停秒数", sRun.playStart == at(88) && sRun.playedAtPause == nil && sRun.playTotal == 48)
check("⭐ 在播、总长未知 ⇒ 只走已播、不画条", pst(active: true, play: mu).playDisplay == .growing(since: at(7)))
check("⭐ 暂停 ⇒ 静态", pst(active: true, paused: true, play: mp).playDisplay == .still(played: 20, total: 48))
check("暂停时卡片不带起点", pst(active: true, paused: true, play: mp).playStart == nil)
check("暂停、总长未知 ⇒ 静态不画条",
      pst(active: true, paused: true, play: mark(paused: true, played: 5, total: nil)).playDisplay == .still(played: 5, total: nil))
check("⭐ 播完能重播 ⇒ 静态停在末尾", pst(active: false, play: mf).playDisplay == .still(played: 48, total: 48))
check("⭐ 没东西 ⇒ 不画", pst(active: false, replay: false, play: .none).playDisplay == .hidden)
check("不传进度（旧调用点）⇒ 不画", mk(active: true, replay: true).playDisplay == .hidden)
check("⭐ 过期版不画进度（app 不在了，接着走就是在编）", sRun.staleVersion.playDisplay == .hidden
      && pst(active: false, play: mf).staleVersion.playDisplay == .hidden)
// makeState 的两道闸跟 isPlaying 同源：哪怕传进来的 mark 跟播放状态对不上，也不会落成矛盾组合
check("mark 说在播、输入说暂停 ⇒ 卡片不带起点", pst(active: true, paused: true, play: m0).playStart == nil)
check("mark 说停着、输入说在播 ⇒ 卡片不带暂停秒数", pst(active: true, play: mp).playedAtPause == nil)
check("过期版连字段一起清掉（扩展以后换种画法也不会拿残值接着走）",
      sRun.staleVersion.playStart == nil && pst(active: false, play: mf).staleVersion.playedAtPause == nil)
var lie = sRun; lie.playStart = nil
check("说在播却没起点 ⇒ 不画（不拿暂停秒数冒充）", lie.playDisplay == .hidden)
var lie2 = sRun; lie2.isPlaying = false
check("不在播、不暂停、不能重播 ⇒ 不画", { var x = lie2; x.canReplay = false; x.playedAtPause = 3; return x.playDisplay == .hidden }())
check("总长 0 落进卡片 ⇒ 当未知", { var x = sRun; x.playTotal = 0; return x.playDisplay == .growing(since: at(88)) }())

check("clock：12 ⇒ 0:12", S.clock(12) == "0:12")
check("clock：48.4 ⇒ 0:48，48.5 ⇒ 0:49（四舍五入，跟 app 播放条一致）", S.clock(48.4) == "0:48" && S.clock(48.5) == "0:49")
check("clock：59.6 ⇒ 1:00（进位不出现 0:60）", S.clock(59.6) == "1:00")
check("clock：768 ⇒ 12:48", S.clock(768) == "12:48")
check("clock：负数 / NaN / 无穷 ⇒ 0:00 不崩", S.clock(-3) == "0:00" && S.clock(.nan) == "0:00" && S.clock(.infinity) == "0:00")
check("fraction 夹在 0…1", S.fraction(played: 60, total: 48) == 1 && S.fraction(played: -1, total: 48) == 0
      && S.fraction(played: 12, total: 48) == 0.25 && S.fraction(played: 3, total: 0) == 0)

// ⑨ 兼容：旧 app 推的卡（没有新键）新扩展照样解码；新 app 推的卡旧扩展照样解码
let noPlay = try! enc.encode(mk(active: true))
let noPlayJSON = String(data: noPlay, encoding: .utf8)!
check("没进度时三个新键都不写进去（体积、也就等于旧 app 的格式）",
      !noPlayJSON.contains("playStart") && !noPlayJSON.contains("playTotal") && !noPlayJSON.contains("playedAtPause"))
/// 旧版 app / 扩展里那份结构体（2026-10-05 之前的字段，原样抄）。
/// ⚠️ 旧格式的样本**必须从这里编出来**，不能拿新结构体编完再删键 —— 新结构体将来要是
/// 多了个非可选字段（比如 `hasClip: Bool`），它自己编出来的 JSON 里就带着那个键，测不出问题。
struct OldState: Codable {
    var room: String; var mood: String; var skin: String; var presence: String; var headline: String
    var subtasks: Int; var timerStart: Date; var isPlaying: Bool; var isPaused: Bool; var canReplay: Bool
    var peers: [S.Peer]
}
let oldJSON = try! enc.encode(OldState(room: "bunny", mood: "speaking", skin: "bunny", presence: "online",
                                       headline: "在说话", subtasks: 0, timerStart: t0, isPlaying: true,
                                       isPaused: false, canReplay: true, peers: []))
let fromOld = try? JSONDecoder().decode(S.self, from: oldJSON)
check("⭐ 旧 app 推的卡（没有新键）⇒ 新扩展解码成功", fromOld != nil)
check("…并且不画进度（不拿缺失当 0 秒画条）", fromOld?.playDisplay == .hidden)
let withPlay = try! enc.encode(sRun)
check("带进度的 JSON 里确实有新键", String(data: withPlay, encoding: .utf8)!.contains("playStart"))
check("⭐ 新 app 带进度的卡 ⇒ 旧扩展照样解码", (try? JSONDecoder().decode(OldState.self, from: withPlay))?.room == "bunny")
check("带进度编解码往返无损", (try? JSONDecoder().decode(S.self, from: withPlay)) == sRun)
let fatPlay = try! enc.encode({ var x = fat; x.playStart = Date(); x.playTotal = 1234.567; x.playedAtPause = 98.7654; return x }())
check("最坏情况带进度仍 < 2 KB", fatPlay.count < 2048, "\(fatPlay.count) 字节")

// ⑦ 端到端：轮询 → playMark → makeState → push，数一共推了几次。
//   一段 48 秒的话，每秒报一次、每次带 ±0.45 秒抖动（外加 RPC 延迟）；第 20 秒暂停 10 秒再继续。
//   该推的只有：开始、暂停、继续、播完 —— 4 次。每秒推就是 60 次。
func simPlay(steps: [(t: Double, active: Bool, paused: Bool, played: Double, total: Double?, fid: String)])
    -> (pushes: Int, last: S?) {
    var memo: M?
    var lastPushed: S?
    var lastAt: Date?
    var n = 0
    for st in steps {
        let now = at(st.t)
        let m = P.playMark(isActive: st.active, isPaused: st.paused, played: st.played, total: st.total,
                           fid: st.fid, previous: memo, now: now)
        memo = m
        let s = pst(active: st.active, paused: st.paused, replay: !st.fid.isEmpty, play: m)
        if case .now = P.push(next: s, last: lastPushed, lastPushAt: lastAt, now: now) {
            lastPushed = s; lastAt = now; n += 1
        }
    }
    return (n, lastPushed)
}
var steps: [(t: Double, active: Bool, paused: Bool, played: Double, total: Double?, fid: String)] = []
var playedSoFar = 0.0
var tt = 0.0
rng = 7
while playedSoFar < 48 {
    let pausedNow = tt >= 20.3 && tt < 30.3
    let jitter = (rnd() - 0.5) * 0.9
    steps.append((tt, true, pausedNow, max(0, min(48, playedSoFar + (pausedNow ? 0 : jitter))), 48, "f1"))
    tt += 1
    if !pausedNow { playedSoFar += 1 }
}
for k in 0..<5 { steps.append((tt + Double(k) * 4, false, false, 48, 48, "f1")) }
let r1 = simPlay(steps: steps)
check("⭐ 48 秒一段、中间暂停一次：只推 4 次（开始 / 暂停 / 继续 / 播完），不是每秒推", r1.pushes == 4,
      "推了 \(r1.pushes) 次 / \(steps.count) 次轮询")
check("最后推出去的是「播完、停在末尾」", r1.last?.playDisplay == .still(played: 48, total: 48))

//   还在生成：前 10 秒总长未知，第 10 秒知道了 ⇒ 开始 1 次 ＋ 总长出现 1 次。
var gsteps: [(t: Double, active: Bool, paused: Bool, played: Double, total: Double?, fid: String)] = []
for k in 0..<30 { gsteps.append((Double(k), true, false, Double(k) + (rnd() - 0.5) * 0.8, k < 10 ? nil : 30, "g")) }
let r2 = simPlay(steps: gsteps)
check("⭐ 生成中→长度出来：只推 2 次", r2.pushes == 2, "推了 \(r2.pushes) 次")

//   卡住等生成（在播但 played 不动 20 秒）：会推纠偏，但有上限 —— 每 ~3 秒一次，不是每秒。
var ssteps: [(t: Double, active: Bool, paused: Bool, played: Double, total: Double?, fid: String)] = []
for k in 0..<20 { ssteps.append((Double(k), true, false, 5, nil, "s")) }
let r3 = simPlay(steps: ssteps)
check("卡住 20 秒：纠偏有、但不超过 20 ÷ 3 ＋ 1 次", r3.pushes >= 2 && r3.pushes <= 7, "推了 \(r3.pushes) 次")

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
    let m = P.playMark(isActive: true, isPaused: false, played: 1, total: 2, fid: "x", previous: nil, now: Date())
    let shown = s.playDisplay == .hidden ? 1 : 0
    return d + s.statusLine.count + s.faceMood.rawValue.count + Int(s.dot.signalHex & 1)
        + (m.isPlaying ? 1 : 0) + shown + S.clock(3).count + Int(S.fraction(played: 1, total: 2) * 2)
}
check("卡片数据和规则能从 nonisolated 上下文用（编译过就算过）", touchFromNonisolated() > 0)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
