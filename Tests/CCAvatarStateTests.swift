// 服务端回报的数字人状态 —— 解析，以及「要不要拿给用户看」。
//
// 这里最容易写错的不是解析，是那条**两个条件都要成立**的规则：
// 服务端那个状态是**全房共享**的（一条视频轨，没法只发给某个人），
// 所以别人开着的时候你也会收到 `on`。直接拿它当「我的状态」用，
// 表现就是：你明明把开关关了，界面上却冒出一块画面、或者弹一条
// 「数字人用不了」的提示 —— 而那跟你毫无关系。
//
// 跑法见 Tests/README.md，被测文件只依赖 Foundation：
//
//   mkdir -p /tmp/swtest && cp VoiceAgent/CloseCrab/CCAvatarState.swift /tmp/swtest/
//   cp Tests/CCAvatarStateTests.swift /tmp/swtest/main.swift
//   docker run --rm -v /tmp/swtest:/w -w /w swift:6.2-noble \
//     bash -c 'swiftc -swift-version 6 -default-isolation MainActor \
//                CCAvatarState.swift main.swift -o t && ./t'

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

typealias S = CCAvatarServerState

// MARK: - 解析

for (raw, want) in [("on", S.on), ("off", .off), ("hidden", .hidden),
                    ("unavailable", .unavailable)] {
    check("\(raw) → \(want)", S.parse(raw) == want, "\(S.parse(raw))")
}
check("大小写不敏感", S.parse("ON") == .on && S.parse("Unavailable") == .unavailable)
check("前后空白不影响", S.parse("  hidden \n") == .hidden)

// ⭐ 服务端哪天多一个状态（比如降级到低帧率），老客户端会走到这里。
//    崩掉或者猜成 off 都不行 —— 前者炸 app，后者会在服务端其实开着时
//    显示「关着」。
check("⭐ 不认识的值 → unknown（不崩、也不猜）", S.parse("degraded") == .unknown)
check("nil → unknown", S.parse(nil) == .unknown)
check("空串 → unknown", S.parse("") == .unknown)

// ⭐ unknown 不能并进 off。「确实关着」和「还没收到消息」要让用户看到
//    不一样的东西 —— 并了的话，服务端根本没回话时界面会假装一切正常。
check("⭐ unknown 和 off 是两个值", S.unknown != S.off)

// MARK: - 该不该报错给用户：两个条件都要成立

// ⭐ 用户自己关着的时候，不管服务端说什么都不该打扰他。
//    尤其 unavailable —— 那是别人的开关引发的，跟他无关。
for state in [S.on, .off, .hidden, .unavailable, .unknown] {
    check("⭐ 开关关着时 \(state) 一律不报", !state.shouldSurfaceProblem(userWants: false))
}

check("开着 + unavailable → 报", S.unavailable.shouldSurfaceProblem(userWants: true))
// ⭐ hidden 特意不报：那说明 app 在后台，屏幕上根本没人看。
//    报了是发给空气，而且回前台时它已经自己变回 on 了。
check("⭐ 开着 + hidden → 不报（在后台，报给谁看）",
      !S.hidden.shouldSurfaceProblem(userWants: true))
check("开着 + on → 不报", !S.on.shouldSurfaceProblem(userWants: true))
check("开着 + off → 不报", !S.off.shouldSurfaceProblem(userWants: true))
// unknown 不报：刚连上还没收到回报是常态，弹一条提示纯属噪音。
check("开着 + unknown → 不报（刚连上还没消息是常态）",
      !S.unknown.shouldSurfaceProblem(userWants: true))

// 只有一种组合会报，穷举确认没有第二种。
let surfacing = [S.on, .off, .hidden, .unavailable, .unknown]
    .filter { $0.shouldSurfaceProblem(userWants: true) }
check("⭐ 只有 unavailable 这一种会报", surfacing == [.unavailable],
      "\(surfacing)")

// MARK: - 该不该腾位置显示画面

// ⭐ 同样要看自己的开关。不看的话，屋里别人开了数字人，
//    你这边会凭空冒出一块画面 —— 而你明明关着。
for state in [S.on, .off, .hidden, .unavailable, .unknown] {
    check("⭐ 开关关着时 \(state) 都不显示画面", !state.shouldShowVideo(userWants: false))
}
let showing = [S.on, .off, .hidden, .unavailable, .unknown]
    .filter { $0.shouldShowVideo(userWants: true) }
check("⭐ 开着时只有 on 显示画面", showing == [.on], "\(showing)")

// MARK: - rawValue 必须跟服务端那四个字符串一模一样

// 改一个字母，两边就对不上，而且**两边都不报错** —— 客户端只是永远
// 解析成 unknown，界面上什么都不显示。所以钉死。
check("⭐ rawValue 跟服务端 AvatarState 的值逐字对齐",
      S.on.rawValue == "on" && S.off.rawValue == "off"
          && S.hidden.rawValue == "hidden" && S.unavailable.rawValue == "unavailable")

// 幂等 / 无状态
for _ in 0 ..< 50 {
    check("纯函数", S.parse("unavailable").shouldSurfaceProblem(userWants: true))
}

// MARK: -

print(failed == 0
    ? "CCAvatarState: \(passed) 条全过"
    : "CCAvatarState: \(passed) 过 / \(failed) 失败")
exit(failed == 0 ? 0 : 1)
