import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// 全 app 共用的两个颜色原语：`Color(hex:)` 和 `Color(light:dark:)`，
/// 外加「正在说话」那个绿。
///
/// ## 它们为什么在这个文件里
///
/// 原来住在 `CCAurora.swift` 的尾巴上 —— 那个文件 2026-09-22 因为省电被整个删掉，
/// **而删之前我差点没发现这三样东西也在里面**：
/// `Color(hex:)` 和 `Color(light:dark:)` 是全 app 的基础设施，
/// `ccSpeaking` 有四个文件在用。整文件 `git rm` 会让构建直接崩。
///
/// ⇒ 教训（跟 [[feedback_look-for-precedent-before-deleting]] 同族）：
/// **删一个文件之前，先列出它导出的全部符号，而不是只看它的文件名在讲什么。**
/// 一个叫「极光」的文件里，最重要的东西可能跟极光毫无关系。

extension Color {
    /// 「正在说话」的绿。
    ///
    /// 写死一个色而不是用 `.green`：系统绿在浅色模式下偏暗、在深色模式下偏荧光，
    /// 而这个信号要求两种模式下都是同一个「说话绿」。取值参考会议软件的通行值。
    static let ccSpeaking = Color(light: Color(hex: 0x1DB954), dark: Color(hex: 0x32E86B))

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// 明暗两份手写色。语义色都在 Assets 里,这个只给上面那几团光用。
    ///
    /// ## 两个 UIColor 必须在闭包外面就算好
    ///
    /// 动态 provider 闭包是 **UIKit 在需要解析颜色时才回调**的，而 SwiftUI 的
    /// `AsyncRenderer` 会在**后台线程**上跑 `ShapeStyleResolver.updateValue()`。
    ///
    /// 工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，闭包不标注就被隐式推成
    /// `@MainActor`；等 UIKit 在非主线程调它，`swift_task_checkIsolatedSwift` 发现
    /// 「声称 MainActor 却不在主队列」，直接 `EXC_BREAKPOINT`：
    ///
    ///     0  _dispatch_assert_queue_fail
    ///     3  _swift_task_checkIsolatedSwift
    ///     5  closure #1 in Color.init(light:dark:)     ← 这里
    ///     7  -[UIDynamicProviderColor _resolvedColorWithTraitCollection:]
    ///    22  ViewGraph.updateOutputsAsync(at:)
    ///
    /// 编译期抓不到 —— 隔离推断在编译期，违反发生在 UIKit 的回调时机。
    /// （09-15 18:19 实际崩过一次，`ccSpeaking` 让方块每帧重算颜色之后必现。）
    ///
    /// ## 光把转换提到闭包外不够，必须 `@Sendable`
    ///
    /// 第一版修法（09-15 19:59）只把 `UIColor(light)` 挪出闭包，19:59 装机、20:02
    /// 就以**完全相同的堆栈**又崩了一次。反汇编闭包看到断言的真实位置：
    ///
    ///     0x3d254  bl  _swift_task_isCurrentExecutor        ← 第 4 条指令
    ///     0x3d288  mov w8, #0xbb                            ← 行号 187
    ///     0x3d28c  bl  _swift_task_reportUnexpectedExecutor
    ///
    /// 检查在**闭包 prologue**，不在闭包体。被推成 `@MainActor` 的是闭包*类型本身*，
    /// 所以进函数第一件事就断言——闭包体写得再干净也没用。
    ///
    /// `@Sendable` 是 Swift 6 里唯一能在**表达式位置**取消 actor 推断的标注，
    /// 加上之后 prologue 里那两条 `swift_task_*` 调用直接消失。
    /// 捕获的 `l` / `d` 必须是 `Sendable`——`UIColor` / `NSColor` 满足。
    ///
    /// 转换提到闭包外仍然保留：既是 `@Sendable` 的前提（避免捕获非 Sendable 的
    /// `Color`），也省掉每帧重做一次 `Color` → `UIColor`。
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
            let l = UIColor(light)
            let d = UIColor(dark)
            self.init(uiColor: UIColor { @Sendable tc in
                tc.userInterfaceStyle == .dark ? d : l
            })
        #else
            let l = NSColor(light)
            let d = NSColor(dark)
            self.init(nsColor: NSColor(name: nil) { @Sendable appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
            })
        #endif
    }
}

// MARK: - bot 身份色

/// 每个 bot 一个颜色。**解决「六个方块长得一模一样」** ——
/// 多房间之后最容易出的错是对着错的助理说话,而名字只有 11pt。
/// 颜色是比文字快一个数量级的识别通道。
enum CCIdentityColor {
    private static let palette: [Color] = [
        Color(hex: 0x7A5CFF), // 靛紫
        Color(hex: 0x38E1B0), // 薄荷
        Color(hex: 0xFF5FA2), // 品红
        Color(hex: 0xFFB020), // 琥珀
        Color(hex: 0x4FC3FF), // 天蓝
        Color(hex: 0xB4FF2E), // 酸绿
    ]

    /// 按名字取色。**用稳定哈希而不是数组下标** ——
    /// 下标会随服务端名单顺序变化,今天 jarvis 是紫的明天变绿,
    /// 而这套颜色的全部价值就在于它不变。
    static func color(for name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
