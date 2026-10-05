// 断线重连规则的测试。
//
// 这条规则的要害是两件「写错了日常也看不出来」的事：
//   ① 不能有上限 —— 有上限就是把「断了不再连」换个时长再犯一次；
//   ② SDK 自己在重连时 isConnected 仍为 true，这时 app 不能插手，否则两层抢着连。
//
// 跑法见 Tests/README.md：
//
//   mkdir -p /tmp/swtest && cp VoiceAgent/CloseCrab/CCReconnectPolicy.swift /tmp/swtest/
//   cp Tests/CCReconnectPolicyTests.swift /tmp/swtest/main.swift
//   docker run --rm -v /tmp/swtest:/w -w /w swift:6.2-noble \
//     bash -c 'swiftc -swift-version 6 -default-isolation MainActor \
//                CCReconnectPolicy.swift main.swift -o t && ./t'

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

typealias P = CCReconnectPolicy

// MARK: - 退避间隔

check("⭐ 第一次重试要快（≤2 秒）", P.delay(attempt: 0) <= 2, "实际 \(P.delay(attempt: 0))")
check("负数次数按第一次算", P.delay(attempt: -3) == P.delay(attempt: 0))
var monotone = true
for n in 0..<20 where P.delay(attempt: n + 1) < P.delay(attempt: n) { monotone = false }
check("间隔单调不减", monotone)
check("⭐ 封顶不超过 60 秒（长时间没网也要隔一会儿就试）", P.delay(attempt: 1000) <= 60,
      "实际 \(P.delay(attempt: 1000))")
check("封顶之后保持最后一档", P.delay(attempt: 1000) == P.delays.last!)
check("间隔都是正数", (0..<50).allSatisfy { P.delay(attempt: $0) > 0 })

// ⭐ 不设上限：第 1000 次照样给出一个有限的等待，而不是「放弃」。
//    这条是在钉需求 —— 任何「超过 N 次就不试了」的改动都应该在这里红。
check("⭐ 第 1000 次仍然会试（有限等待）", P.delay(attempt: 1000).isFinite)

// MARK: - 该不该试：2×2×2 真值表

for want in [false, true] {
    for connected in [false, true] {
        for inFlight in [false, true] {
            let got = P.shouldRetry(wantConnected: want, isConnected: connected, inFlight: inFlight)
            let expect = want && !connected && !inFlight
            check("want=\(want) connected=\(connected) inFlight=\(inFlight)", got == expect)
        }
    }
}
check("⭐ 用户挂断后不再连", !P.shouldRetry(wantConnected: false, isConnected: false, inFlight: false))
check("⭐ SDK 自己在重连（isConnected 仍 true）时 app 不插手",
      !P.shouldRetry(wantConnected: true, isConnected: true, inFlight: false))
check("已有一次连接在路上时不重复发起",
      !P.shouldRetry(wantConnected: true, isConnected: false, inFlight: true))

// MARK: - 红条什么时候亮

check("⭐ 第一次失败不亮红条", !P.showsError(failures: 0))
check("⭐ 安静期吃得下一次 bot 重启（前几次等待合计 ≥10 秒）",
      (0..<P.quietAttempts).map { P.delay(attempt: $0) }.reduce(0, +) >= 10)
check("⭐ 安静期不超过 1 分钟（真坏了要让人知道）",
      (0..<P.quietAttempts).map { P.delay(attempt: $0) }.reduce(0, +) <= 60)
check("安静期边界：第 quietAttempts 次失败起亮红条", P.showsError(failures: P.quietAttempts))
check("安静期边界：前一次不亮", !P.showsError(failures: P.quietAttempts - 1))

print(failed == 0 ? "✓ \(passed) 条全过" : "✗ \(failed) 条失败 / \(passed) 条通过")
exit(failed == 0 ? 0 : 1)
