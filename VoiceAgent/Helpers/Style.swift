import SwiftUI

extension CGFloat {
    /// The grid spacing used as a design unit.
    static let grid: Self = 4

    #if os(visionOS)
        /// The corner radius for the platform-specific UI elements.
        static let cornerRadiusPerPlatform: Self = 11.5 * grid
    #else
        /// The corner radius for the platform-specific UI elements.
        static let cornerRadiusPerPlatform: Self = 2 * grid
    #endif

    /// The corner radius for the small UI elements.
    static let cornerRadiusSmall: Self = 2 * grid

    /// The corner radius for the large UI elements.
    static let cornerRadiusLarge: Self = 4 * grid
}

/// 主操作按钮：**近黑实心胶囊 ＋ 白字**，深色模式下整个反过来。
///
/// ## 为什么主按钮不用品牌色
///
/// Chris 2026-09-21 拿 Perplexity 的登录页当参照：「这种按钮的配色是我想要的。」
/// 那一屏上**唯一的彩色是右下角那颗很小的语音钮**，而主操作「登录」
/// 是一颗近黑的胶囊。
///
/// 这套做法这两年成了新的默认，理由站得住：
///
/// 1. **品牌色铺在最大的那块上，它就不再是强调色了。** 强调色靠稀缺生效 ——
///    一屏上只有一处彩色时，眼睛自动知道去哪；三处都彩，就等于没有重点。
/// 2. **近黑/近白是对比度最高的一对**，任何背景上都读得清，
///    不用为每种背景调一遍。品牌色做不到这点（我们那支电紫在浅色背景上
///    对比度就是勉强及格）。
/// 3. **它不跟内容抢注意力。** 内容区有波形、有头像、有身份色，
///    主按钮再来一块饱和色，整屏就没有安静的地方了。
///
/// ⇒ 颜色的分工变成：**主操作用明度（黑/白），身份和状态用色相。**
///
/// ## 为什么是胶囊不是圆角矩形
///
/// 8pt 圆角的矩形按钮是 2015 年那一代的样子。全圆角（胶囊）现在是
/// iOS / Android / Web 共同的主操作形状 —— 而且它**自带「可按」的语义**，
/// 方角块更容易被读成一个色块或者横幅。
struct CCPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    /// 暖中性的近黑 / 近白。**特意不用 `fg0`** ——
    /// 那支是文字色，带着这套主题残留的紫调（#13142B）。
    /// 主按钮是整屏最大的一块实色，带一点色偏就会被看出来。
    private static let fill = Color(light: Color(hex: 0x1C1B1A), dark: Color(hex: 0xF2F1EF))
    private static let label = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1C1B1A))

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isEnabled ? Self.label : Self.label.opacity(0.6))
            .background(
                Capsule().fill(
                    isEnabled
                        ? Self.fill.opacity(configuration.isPressed ? 0.82 : 1)
                        : Self.fill.opacity(0.28)
                )
            )
            .contentShape(Capsule())
    }
}

struct ProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textCase(.uppercase)
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .background(.fgAccent.opacity(configuration.isPressed ? 0.75 : 1))
            .cornerRadius(8)
    }
}

struct RoundButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .background(isEnabled ? .fgAccent.opacity(configuration.isPressed ? 0.75 : 1) : .fg4.opacity(0.4))
            .clipShape(Circle())
    }
}

struct ControlBarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    var isToggled: Bool = false
    let foregroundColor: Color
    let backgroundColor: Color
    let borderColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isEnabled ? foregroundColor : borderColor)
            // 选中态用一块实心药丸，跟系统标签栏选中项一致。
            // 未选中**什么都不画** —— 整条已经是一块玻璃了，
            // 每个按钮再来一层底会把那块玻璃切得稀碎。
            .background {
                if isToggled {
                    Capsule().fill(backgroundColor)
                }
            }
            // 按下去缩一点。原来只改透明度，在玻璃上几乎看不出来。
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .ccAnimation(CC.Motion.press, value: configuration.isPressed)
    }
}

struct BlurredTop: ViewModifier {
    func body(content: Content) -> some View {
        content.mask(
            LinearGradient(
                gradient: Gradient(colors: [.clear, .black, .black]),
                startPoint: .top,
                endPoint: .init(x: 0.5, y: 0.2)
            )
        )
    }
}

struct Shimmering: ViewModifier {
    @State private var isShimmering = false

    func body(content: Content) -> some View {
        content
            .mask(
                LinearGradient(
                    colors: [
                        .black.opacity(0.4),
                        .black,
                        .black,
                        .black.opacity(0.4),
                    ],
                    startPoint: isShimmering ? UnitPoint(x: 1, y: 0) : UnitPoint(x: -1, y: 0),
                    endPoint: isShimmering ? UnitPoint(x: 2, y: 0) : UnitPoint(x: 0, y: 0)
                )
                .ccDecorativeAnimation(.linear(duration: 2).repeatForever(autoreverses: false), value: isShimmering)
            )
            .onAppear {
                isShimmering = true
            }
    }
}

extension View {
    func blurredTop() -> some View {
        modifier(BlurredTop())
    }

    func shimmering() -> some View {
        modifier(Shimmering())
    }
}
