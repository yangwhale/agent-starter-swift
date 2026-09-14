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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            Color.bg1

            blob(.auroraViolet, size: 1.15, x: -0.38, y: -0.34, phase: 0)
            blob(.auroraTeal, size: 0.95, x: 0.42, y: -0.08, phase: 1)
            blob(.auroraMagenta, size: 1.05, x: -0.18, y: 0.40, phase: 2)

            if let tint {
                // 当前 bot 的身份色渗进环境里。压得很低(0.16)——
                // 它是「氛围」不是「主题皮肤」,浓了就变成花屏。
                RadialGradient(
                    colors: [tint.opacity(0.16), .clear],
                    center: .init(x: 0.5, y: 0.32),
                    startRadius: 0,
                    endRadius: 420
                )
                .blendMode(.plusLighter)
                .animation(.easeInOut(duration: 1.2), value: tint)
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

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// 明暗两份手写色。语义色都在 Assets 里,这个只给上面那几团光用。
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
            self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #else
            self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light) })
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
