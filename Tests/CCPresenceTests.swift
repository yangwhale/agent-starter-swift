// 在线状态小圆点的测试。
//
// 要钉住的是几条「写错了日常也看不出来」的优先级：
//   ① 用户主动挂断 → 灰，不能是红（红是「出事了」，挂断不是事故）；
//   ② 断线但还想连 → 红，不能是灰（灰会让人以为是自己没点开始）；
//   ③ 刚连上质量未知 → 绿，不能是橙（否则每次连接都闪一下橙）；
//   ④ SDK 自己在重连 → 黄，不能是红（它很可能几秒就自己好了）。
//
// 跑法见 Tests/README.md：
//
//   mkdir -p /tmp/swtest && cp VoiceAgent/CloseCrab/CCPresence.swift /tmp/swtest/
//   cp Tests/CCPresenceTests.swift /tmp/swtest/main.swift
//   docker run --rm -v /tmp/swtest:/w -w /w swift:6.2-noble \
//     bash -c 'swiftc -swift-version 6 -default-isolation MainActor \
//                CCPresence.swift main.swift -o t && ./t'

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

typealias D = CCPresenceDot

func dot(_ want: Bool, _ phase: CCPresencePhase, bot: Bool = true, q: CCPresenceQuality = .good) -> D {
    D.derive(wantConnected: want, phase: phase, botPresent: bot, quality: q)
}

// MARK: - 四条要害

check("⭐ 主动挂断是灰不是红", dot(false, .disconnected) == .off)
check("⭐ 断线但还想连是红", dot(true, .disconnected) == .retrying)
check("⭐ 刚连上质量未知是绿", dot(true, .connected, q: .unknown) == .online)
check("⭐ SDK 自己重连是黄", dot(true, .reconnecting) == .connecting)

// MARK: - 其余组合

check("正在连是黄", dot(true, .connecting) == .connecting)
check("连着、bot 在、网好是绿", dot(true, .connected, q: .excellent) == .online)
check("bot 不在是橙", dot(true, .connected, bot: false) == .degraded)
check("网络差是橙", dot(true, .connected, q: .poor) == .degraded)
check("网络丢失是橙", dot(true, .connected, q: .lost) == .degraded)
check("bot 不在优先于网好", dot(true, .connected, bot: false, q: .excellent) == .degraded)

// 连接相位一旦不是 connected，bot 在不在、网好不好都不影响 —— 那些信号此刻没意义。
for want in [false, true] {
    for bot in [false, true] {
        for q in [CCPresenceQuality.unknown, .lost, .poor, .good, .excellent] {
            check("connecting 不看 bot/质量 want=\(want) bot=\(bot) q=\(q)",
                  dot(want, .connecting, bot: bot, q: q) == .connecting)
            check("disconnected 不看 bot/质量 want=\(want) bot=\(bot) q=\(q)",
                  dot(want, .disconnected, bot: bot, q: q) == (want ? .retrying : .off))
        }
    }
}

// 每个状态都有读屏文字，而且互不相同 —— 不能只靠颜色。
let all: [D] = [.off, .retrying, .connecting, .degraded, .online]
check("每个状态都有读屏文字", all.allSatisfy { !$0.spoken.isEmpty })
check("读屏文字互不相同", Set(all.map(\.spoken)).count == all.count)

print(failed == 0 ? "✓ \(passed) 条全过" : "✗ \(failed) 条失败 / \(passed) 条通过")
exit(failed == 0 ? 0 : 1)
