// 「减弱动态效果」判定的真值表测试。
//
// 这条规则的特殊之处：**它只在用户打开了辅助功能开关时才生效**。
// 开发、演示、给人看 demo 的时候永远走不到那条分支 —— 写反了没有任何人会发现，
// 直到一个真正需要它的人装上 app，发现要么界面在硬跳、要么转圈停了像卡死。
//
// 跑法见 Tests/README.md，被测文件只依赖 Foundation：
//
//   mkdir -p /tmp/swtest && cp VoiceAgent/CloseCrab/CCMotionPolicy.swift /tmp/swtest/
//   cp Tests/CCMotionPolicyTests.swift /tmp/swtest/main.swift
//   docker run --rm -v /tmp/swtest:/w -w /w swift:6.2-noble \
//     bash -c 'swiftc -swift-version 6 -default-isolation MainActor \
//                CCMotionPolicy.swift main.swift -o t && ./t'

import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ got: CCMotionResolution, _ want: CCMotionResolution) {
    if got == want {
        passed += 1
    } else {
        failed += 1
        print("  ✗ \(label): 期望 \(want)，实际 \(got)")
    }
}

// MARK: - 完整真值表（2×2，一格都不能省）

check("开关关 ＋ 状态切换 → 原样",
      CCMotionPolicy.resolve(reduceMotion: false, decorative: false), .asRequested)

// ⚠️ 这一格最容易写错：装饰性动画在开关**关着**时也必须原样播。
// 判断顺序写成「先看 decorative」的话这里会变成 .still —— 所有人都看不到转圈了，
// 而且那是个静默退化，不会有任何报错。
check("开关关 ＋ 纯装饰   → 原样（不是 still！）",
      CCMotionPolicy.resolve(reduceMotion: false, decorative: true), .asRequested)

// 状态切换不能直接不动：硬跳看着像界面卡了一下，比动画更刺激。
check("开关开 ＋ 状态切换 → 淡出（不是 still！）",
      CCMotionPolicy.resolve(reduceMotion: true, decorative: false), .fade)

check("开关开 ＋ 纯装饰   → 完全不动",
      CCMotionPolicy.resolve(reduceMotion: true, decorative: true), .still)

// MARK: - 不变量

// 开关关着时，decorative 这个参数**完全不该有影响**。
// 写成一条独立断言而不是靠上面两格隐含 —— 意图不一样：
// 上面测的是具体取值，这条测的是「这个维度在这种情况下不参与决策」。
check("开关关时 decorative 不参与决策",
      CCMotionPolicy.resolve(reduceMotion: false, decorative: true),
      CCMotionPolicy.resolve(reduceMotion: false, decorative: false))

// 开关开着时，两种 decorative 必须给出**不同**结果 —— 否则这个参数就是摆设。
if CCMotionPolicy.resolve(reduceMotion: true, decorative: true)
    == CCMotionPolicy.resolve(reduceMotion: true, decorative: false) {
    failed += 1
    print("  ✗ 开关开时 decorative 没有区分度，这个参数等于白加")
} else {
    passed += 1
}

// 纯函数：同样输入必须同样输出（防止哪天有人往里塞全局状态）。
for _ in 0 ..< 50 {
    check("幂等", CCMotionPolicy.resolve(reduceMotion: true, decorative: false), .fade)
}

// MARK: -

print(failed == 0
    ? "CCMotionPolicy: \(passed) 条全过"
    : "CCMotionPolicy: \(passed) 过 / \(failed) 失败")
exit(failed == 0 ? 0 : 1)
