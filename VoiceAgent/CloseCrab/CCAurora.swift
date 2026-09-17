import SwiftUI

/// 背景那层极光。**整套视觉的地基,不是装饰。**
///
/// ## 为什么非有不可
///
/// 之前深色模式底色是 `#070707`,离纯黑 3%。而 Liquid Glass 的效果来自
/// **折射背后的内容** + 采集环境色做高光 —— 背后是一片黑,玻璃就没东西可折射,
/// `.glassEffect()` 渲染出来只是一块半透明灰矩形,跟 iOS 7 的毛玻璃没区别,
/// 白付一份性能代价。
///
/// 所以「界面 low」在这个 app 里首先是个物理问题:不是玻璃用错了
/// (工程其实是对的),是背后没给它东西可折射。这一层就是折射源。
///
/// ## 三团光怎么摆
///
/// 三个超大半径的模糊色块,以 20–40 秒的周期极缓慢漂移。周期必须长 ——
/// 快了就成了屏保,而它的职责是「让玻璃有内容可折射」,不是吸引注意力。
/// 用户不该注意到它在动,只该觉得这块屏幕是活的。
struct CCAuroraBackground: View {
    /// 当前 bot 的主题色。切 bot 时整片极光的色相跟着转 ——
    /// 换助理不只是内容换了,环境的光也变了。
    var tint: Color?

    /// 画不画最底下那层 `Color.bg1`。
    ///
    /// **`CCBackdrop` 在它下面垫了一张图时必须传 `false`** ——
    /// `bg1` 是不透明的,画了就等于把图整个盖掉,而症状是「背景图设了没反应」。
    var showsBase: Bool = true

    /// 整体强度,0–1。有背景图时压到 0.4 出头:
    /// 两层都开满会互相打架,出来一片浑浊的紫。
    var intensity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            if showsBase { Color.bg1 }

            Group {
                blob(.auroraViolet, size: 1.15, x: -0.38, y: -0.34, phase: 0)
                blob(.auroraTeal, size: 0.95, x: 0.42, y: -0.08, phase: 1)
                blob(.auroraMagenta, size: 1.05, x: -0.18, y: 0.40, phase: 2)
            }
            .opacity(intensity)

            if let tint {
                // 当前 bot 的身份色渗进环境里。压得很低(0.16)——
                // 它是「氛围」不是「主题皮肤」,浓了就变成花屏。
                //
                // 身份色**不跟着 intensity 一起压**:它承担的是「现在在跟谁说话」
                // 这条信息,不是装饰。有图的时候环境更花,反而更需要它站得住。
                RadialGradient(
                    colors: [tint.opacity(0.16), .clear],
                    center: .init(x: 0.5, y: 0.32),
                    startRadius: 0,
                    endRadius: 420
                )
                .blendMode(.plusLighter)
                .ccAnimation(.easeInOut(duration: 1.2), value: tint)
            }

            // 噪点。**不是为了做旧** —— 大面积渐变在 8bit 屏上会出色带(banding),
            // 一层极淡的噪点能把色带打散。这是 mesh gradient 的标准配套。
            CCFilmGrain()
                .opacity(0.055)
                .blendMode(.overlay)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .onAppear { drift = true }
    }

    private func blob(_ color: Color, size: CGFloat,
                      x: CGFloat, y: CGFloat, phase: Double) -> some View
    {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height) * size
            Ellipse()
                .fill(color)
                .frame(width: side, height: side * 0.82)
                .blur(radius: 110)
                .offset(
                    x: proxy.size.width * x + (drift && !reduceMotion ? 26 * (phase == 1 ? -1 : 1) : 0),
                    y: proxy.size.height * y + (drift && !reduceMotion ? 20 * (phase == 2 ? -1 : 1) : 0)
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                // 三团用不同周期,避免同步漂移形成「整体平移」的廉价感。
                .animation(
                    reduceMotion ? nil :
                        .easeInOut(duration: 26 + phase * 6).repeatForever(autoreverses: true),
                    value: drift
                )
        }
    }
}

/// 细噪点。
///
/// 用 `Canvas` 一次性画出来而不是贴图:省一个资源文件,而且能随尺寸自适应。
/// 画一次就够 —— 动态噪点(每帧重绘)在这个尺寸上是纯粹的耗电。
private struct CCFilmGrain: View {
    var body: some View {
        Canvas { context, size in
            var generator = SystemRandomNumberGenerator()
            let step: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    if Bool.random(using: &generator) {
                        let v = Double.random(in: 0.25 ... 1, using: &generator)
                        context.fill(
                            Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                            with: .color(.white.opacity(v))
                        )
                    }
                    x += step
                }
                y += step
            }
        }
        .drawingGroup()
    }
}

// MARK: - 极光色

extension Color {
    /// 极光的三团光。**不走 Assets** —— 它们不是语义色(不表示任何状态),
    /// 只是背景材质的构成,放进色板会污染「语义色」这个概念。
    static var auroraViolet: Color {
        Color(light: Color(hex: 0xD9CCFF).opacity(0.62), dark: Color(hex: 0x3B1E6E).opacity(0.85))
    }

    static var auroraTeal: Color {
        Color(light: Color(hex: 0xC7F0E4).opacity(0.62), dark: Color(hex: 0x0B4F6C).opacity(0.80))
    }

    static var auroraMagenta: Color {
        Color(light: Color(hex: 0xFFD9EC).opacity(0.55), dark: Color(hex: 0x6E1E4A).opacity(0.70))
    }

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
