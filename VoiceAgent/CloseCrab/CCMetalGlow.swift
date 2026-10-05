import Foundation
#if canImport(SwiftUI)
    import SwiftUI
#endif

/// 声音柱子那套「微微发光的金属」质感 —— **柱子和活脸共用这一份**。
///
/// 原来整套写在 `CCVoiceBars` 里（`metal` 渐变 ＋ body 上三道 `shadow`）。
/// Chris 2026-10-05 要活脸用同一种材质：「跟柱子一模一样」。复制一份的话两边迟早调得不一样，
/// 而「一样」恰恰是这件事的全部要求 —— 所以抽出来，两边都只引用。
///
/// ⚠️ **柱子的行为必须完全不变**：stops、blendMode、tint 动画、三道阴影的参数都是原样搬过来的，
/// 改这里就是同时改柱子和脸。
///
/// ## 为什么要有那道暗向接触阴影（原注释，搬过来）
///
/// 只有 tint 辉光时，金属本身是白色渐变，浅色模式下压在亮背景（云图）上等于白压白，
/// 直接消失 —— 而且因为它还在动，你甚至不会觉得是「坏了」，只会觉得「没东西」。
/// 辉光救不了这个：辉光是加亮，亮背景上加亮＝更看不见。
/// 需要的是一道往下沉的暗边，把形状从背景里抠出来。
/// **活脸在浅色模式下也靠它**，所以不需要另配一套深色线条。
///
/// ## 文件结构
///
/// 数值放在只依赖 Foundation 的 `CCMetalGlowSpec` 里（Linux 上离线测，见 Tests/README.md），
/// SwiftUI 那一半包在 `#if canImport(SwiftUI)` 里 —— 测试台编得过这个文件，只是看不到视图。
nonisolated enum CCMetalGlowSpec {
    /// 暗向接触阴影的不透明度。浅色模式要更重 —— 它是浅底上唯一的轮廓。
    static func contactOpacity(dark: Bool) -> Double { dark ? 0.18 : 0.34 }
    static let contactRadius: Double = 3
    static let contactY: Double = 1

    /// 两层 tint 辉光：(不透明度, 半径)。半径乘 `glow` —— 小尺寸要按比例收，
    /// 不然一个 22pt 的东西拖着 40pt 的光晕。
    static func halos(glow: Double) -> [(opacity: Double, radius: Double)] {
        [(0.55, 18 * glow), (0.28, 40 * glow)]
    }

    /// 活脸按边长取 glow：主页面大脸（≥220pt）＝ 1，跟大柱子一样；
    /// 方块上 ~50pt 约 0.23，跟方块上的小柱子（0.22）一个量级；侧栏 22pt 封底 0.1。
    static func faceGlow(side: Double) -> Double {
        min(1, max(0.1, side / 220))
    }
}

#if canImport(SwiftUI)

    /// 金属 ＝ 纵向亮暗亮暗多段跳 ＋ 一道斜向高光。
    /// 单向渐变（上亮下暗）只会得到塑料：金属像金属，是因为它把环境里的
    /// 亮带和暗带一起反射进来。
    ///
    /// 用法：`CCMetal(tint:).mask { 形状 }` —— 形状只管轮廓，颜色全在这里。
    struct CCMetal: View {
        let tint: Color

        var body: some View {
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.95), location: 0.00),
                        .init(color: tint.opacity(0.80), location: 0.14),
                        .init(color: tint, location: 0.34),
                        .init(color: .white.opacity(0.88), location: 0.50),
                        .init(color: tint, location: 0.64),
                        .init(color: tint.opacity(0.55), location: 0.82),
                        .init(color: .white.opacity(0.90), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                LinearGradient(
                    colors: [.white.opacity(0.55), .clear, .white.opacity(0.25), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.plusLighter)
            }
            .ccAnimation(.easeInOut(duration: 0.5), value: tint)
        }
    }

    /// 三道阴影：先一道**暗向**接触阴影，再叠两层 tint 辉光。
    /// 辉光跟着遮罩的 alpha 走，所以是从形状本身散出来的，不是一个方块的外发光。
    struct CCMetalGlow: ViewModifier {
        @Environment(\.colorScheme) private var scheme
        let tint: Color
        let glow: CGFloat

        func body(content: Content) -> some View {
            let halos = CCMetalGlowSpec.halos(glow: Double(glow))
            content
                .shadow(color: .black.opacity(CCMetalGlowSpec.contactOpacity(dark: scheme == .dark)),
                        radius: CCMetalGlowSpec.contactRadius, y: CCMetalGlowSpec.contactY)
                .shadow(color: tint.opacity(halos[0].opacity), radius: halos[0].radius)
                .shadow(color: tint.opacity(halos[1].opacity), radius: halos[1].radius)
        }
    }

    extension View {
        /// 声音柱子那三道阴影。`glow` 是辉光半径的倍数（大柱子 1，方块上 0.22）。
        func ccMetalGlow(tint: Color, glow: CGFloat) -> some View {
            modifier(CCMetalGlow(tint: tint, glow: glow))
        }
    }

#endif
