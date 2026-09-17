// 「用户现在看得见画面吗」去抖的测试。
//
// 这条规则的特殊之处：**它的两个方向代价不对称，而代码里看不出来**。
// 「关要慢、开要快」写成对称的（两边都等 8 秒、或者两边都立刻），
// 编译一样过、日常用一样顺 —— 只有在真正需要它的场景才现形：
// 扫一眼通知再回来，画面莫名其妙断掉又重起。
//
// 另一半理由是省钱：判成「看不见」服务端就会放掉一路 GPU 槽位（一共 8 路）。
// 抖一下就放、放完马上又抢，比不放还贵。
//
// 跑法见 Tests/README.md，被测文件只依赖 Foundation：
//
//   mkdir -p /tmp/swtest && cp VoiceAgent/CloseCrab/CCVisibilityPolicy.swift /tmp/swtest/
//   cp Tests/CCVisibilityPolicyTests.swift /tmp/swtest/main.swift
//   docker run --rm -v /tmp/swtest:/w -w /w swift:6.2-noble \
//     bash -c 'swiftc -swift-version 6 -default-isolation MainActor \
//                CCVisibilityPolicy.swift main.swift -o t && ./t'

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

let grace = CCVisibilityPolicy.backgroundGrace

// MARK: - 宽限期本身要落在有意义的区间

// ⭐ 下面所有断言都拿 `grace` 当基准，所以**它们会跟着这个常量一起缩放** ——
//    把它改成 0 的话，整套测试照样全绿，而去抖等于不存在。
//    （2026-09-17 变异测试就是这么漏的一条。）
//    所以这里必须单独钉住区间，而且钉的是**需求**不是数字：
//
//      下界 3 秒 —— 要明显长过「拉下通知中心看一眼再回来」
//      上界 30 秒 —— 用户真切走之后，白烧一路 GPU 槽位能忍的上限
//
//    中间这一段很宽，改成 5 或 15 都不会红；只有改成「没有去抖」
//    或者「久到离谱」才会。
check("⭐ 宽限期长过一次扫视（≥3 秒）", grace >= 3, "实际 \(grace)")
check("⭐ 宽限期短过白烧 GPU 的忍耐上限（≤30 秒）", grace <= 30, "实际 \(grace)")

// MARK: - 初值

var p = CCVisibilityPolicy()
// app 起来的第一刻就是前台。初值写成 false 的话，第一次上报会是「看不见」，
// 服务端据此不开画面 —— 而用户明明正盯着屏幕。
check("⭐ 初值是看得见", p.isVisible)
check("前台时不用排定时器", p.deadline(from: 0) == nil)

// MARK: - 回前台：立刻，不等

p = CCVisibilityPolicy()
p.update(phase: .background, now: 0)
_ = p.tick(now: grace + 1)
check("后台待够了 → 看不见", !p.isVisible)
let changed = p.update(phase: .active, now: grace + 2)
// ⭐ 「开」这个方向一秒都不能等。用户已经在看屏幕了，
//    再等 8 秒才上报，他就盯着一块空白看 8 秒。
check("⭐ 回前台立刻恢复，不等宽限", p.isVisible)
check("恢复这次要返回「变了」（否则不会上报）", changed)

// MARK: - 进后台：要等满，而且是「等满」不是「等到」

p = CCVisibilityPolicy()
let intoBg = p.update(phase: .background, now: 100)
// ⭐ 刚进后台不算变 —— 这一步要是返回 true，就会立刻上报「看不见」，
//    整个宽限期等于白写。
check("⭐ 刚进后台还看得见（没有立刻翻）", p.isVisible)
check("⭐ 刚进后台不算「变了」，不该触发上报", !intoBg)

check("差一点点，不翻", !p.tick(now: 100 + grace - 0.001) && p.isVisible)
check("刚好到点，翻", p.tick(now: 100 + grace) && !p.isVisible)
// 翻过去之后再 tick 不该反复返回「变了」—— 那会让上报一直重发。
check("⭐ 翻过之后再 tick 不再报变化", !p.tick(now: 100 + grace + 99))

// MARK: - 宽限期内回来：计时必须清零，不能累计

p = CCVisibilityPolicy()
p.update(phase: .inactive, now: 0)       // 拉下通知中心
p.update(phase: .active, now: 2)         // 两秒后回来
check("扫一眼通知再回来，全程看得见", p.isVisible)
p.update(phase: .background, now: 3)     // 又走了
// ⭐ 这一条抓「累计」写法：如果计时没在回前台时清零，之前那 2 秒会被算进去，
//    这次只要再过 6 秒就翻 —— 表现是「刚切走一下就断了」，而且时长每次都不同，
//    查起来像随机 bug。
check("⭐ 回过一次前台，计时从头算（不累计之前那 2 秒）",
      !p.tick(now: 3 + grace - 0.001) && p.isVisible)
check("从新起点算满才翻", p.tick(now: 3 + grace) && !p.isVisible)

// MARK: - inactive 和 background 一视同仁

for phase in [CCScenePhaseKind.inactive, .background] {
    var q = CCVisibilityPolicy()
    q.update(phase: phase, now: 0)
    check("\(phase) 刚进不翻", q.isVisible)
    check("\(phase) 等满才翻", q.tick(now: grace) && !q.isVisible)
}

// 连着在两个「非前台」态之间跳（来电横幅 → 真的切走），计时不该重置。
// ⭐ 重置的话，反复弹横幅可以让宽限永远到不了，槽位就一直占着。
p = CCVisibilityPolicy()
p.update(phase: .inactive, now: 0)
p.update(phase: .background, now: 3)
check("⭐ inactive→background 不重置计时（否则能被无限拖住）",
      p.tick(now: grace) && !p.isVisible)

// MARK: - deadline：排定时器用

p = CCVisibilityPolicy()
check("前台时没有 deadline", p.deadline(from: 0) == nil)
p.update(phase: .background, now: 10)
check("刚进后台，deadline 是整个宽限", p.deadline(from: 10) == grace,
      "\(String(describing: p.deadline(from: 10)))")
check("过了一半，deadline 剩一半", p.deadline(from: 10 + grace / 2) == grace / 2)
// ⭐ 已经翻成看不见之后必须返回 nil。不然调用方会排出一串永远什么都不做的
//    定时器，在后台持续唤醒 —— 语音 app 本来就在后台跑着，这是实打实的耗电。
_ = p.tick(now: 10 + grace)
check("⭐ 已经看不见了就不用再排定时器", p.deadline(from: 10 + grace) == nil)
// 时钟已经过了 deadline（定时器晚醒了）也不能给负数 —— 会被当成「立刻再排」。
p = CCVisibilityPolicy()
p.update(phase: .background, now: 0)
check("⭐ 定时器晚醒时 deadline 不为负", (p.deadline(from: grace + 5) ?? -1) >= 0)

// MARK: - 幂等 / 无副作用

p = CCVisibilityPolicy()
p.update(phase: .background, now: 0)
for _ in 0 ..< 50 {
    check("宽限内反复 tick 不会提前翻", !p.tick(now: grace - 1) && p.isVisible)
}
p = CCVisibilityPolicy()
for i in 0 ..< 20 {
    let c = p.update(phase: .active, now: Double(i))
    check("已经在前台，再报 active 不算变化", !c && p.isVisible)
}

// MARK: -

print(failed == 0
    ? "CCVisibilityPolicy: \(passed) 条全过"
    : "CCVisibilityPolicy: \(passed) 过 / \(failed) 失败")
exit(failed == 0 ? 0 : 1)
