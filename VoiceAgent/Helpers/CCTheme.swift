import SwiftUI

/// 这一版界面的设计常量。
///
/// ## 为什么单独一个文件
///
/// 之前圆角是 `2 * .grid`、`7.5 * .grid`、`15` 这样散在各处，改一次要全局搜。
/// 更糟的是**没有统一语汇**：同样是「卡片」，一处 8pt 一处 30pt，
/// 谁也说不清哪个是对的。数值收在这里之后，「卡片圆角」就只有一个答案。
///
/// ## 取值依据
///
/// 圆角全部用 `.continuous`（squircle），这是 iOS 自己在用的曲线 ——
/// 普通圆角在大半径时肩部会有明显的曲率突变，跟系统控件摆一起一眼看得出不是一家的。
///
/// 尺寸按 Apple HIG 的 44pt 最小点击区往上取：主操作 56，次级 44。
enum CC {
    // MARK: - 圆角

    enum Radius {
        /// 内容窗口这种大块。
        static let card: CGFloat = 28
        /// 底部两条（说话条、控制栏）。接近半高，看着是胶囊但保留一点方形感。
        static let bar: CGFloat = 28
        /// 头像方块。
        static let tile: CGFloat = 16
        /// 小徽标、小药丸。
        static let chip: CGFloat = 10
    }

    // MARK: - 尺寸

    enum Size {
        /// 说话条。**主操作要比一般按钮大一号** —— 它是这个 app 里按得最频繁的东西，
        /// 而且经常在走路/单手时按，44 不够。
        static let talkBar: CGFloat = 64
        /// 控制栏。
        static let controlBar: CGFloat = 56
        /// 控制栏里单个按钮的点击区，HIG 下限。
        static let tapTarget: CGFloat = 44
        /// 头像方块。
        static let tile: CGFloat = 54
        /// 内容列的最大宽度。
        ///
        /// **给 iPad 用的**（device family 一直是 `1,2,7`，iPad 从来就在支持列表里，
        /// iPad mini 也不是单独一档 —— 它就是台 iPad）。
        ///
        /// 这个 app 的信息密度是按手机设计的：一排方块、一条波形、两条操作栏。
        /// 不限宽的话，在 iPad 上那块内容窗口会被拉成一张空旷的大白板，
        /// 底下两条操作栏横跨整个屏幕 —— 拇指够不到两头，而且看着不像一个
        /// 「为这块屏设计过」的界面，像手机版被抻开了。
        ///
        /// 560 是按「一条操作栏仍然一只手够得着」取的。iPhone 上比屏还宽，
        /// 所以是**空操作**，不影响现有手机布局。
        static let contentMax: CGFloat = 560
    }

    // MARK: - 间距

    enum Space {
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 6
        static let snug: CGFloat = 10
        static let regular: CGFloat = 16
        static let loose: CGFloat = 24
        static let section: CGFloat = 32
        /// 屏幕左右安全边距。App Store 用的也是 16。
        static let screen: CGFloat = 16
    }

    // MARK: - 动画

    /// **全 app 只用这三条**。动画曲线不统一是「廉价感」最大的来源之一：
    /// 同一个界面上，一个元素弹、一个元素滑、一个元素淡入，看着像三个人做的。
    enum Motion {
        /// 位移、切换。带一点回弹，模拟实体被推动。
        static let snap = Animation.spring(response: 0.32, dampingFraction: 0.82)
        /// 状态变色、出现消失。不要回弹 —— 颜色弹一下很廉价。
        static let fade = Animation.easeOut(duration: 0.18)
        /// 按下反馈。必须短，超过 0.12 就有延迟感。
        static let press = Animation.easeOut(duration: 0.1)
    }

    // MARK: - 字阶

    /// **字阶比拉到 3 倍以上**。之前最大 `.headline` 最小 `.caption2`,
    /// 差不到 2 倍,整屏没有视觉焦点 —— 这是「看着廉价」的第二大来源
    /// (第一是背景,见 CCAuroraBackground)。
    ///
    /// 一个中文的硬约束:**PingFang SC 只有 6 个字重,最粗到 Semibold,
    /// 没有 Bold 也没有 Black**,而 SF Pro 有到 900。所以中文要「大」
    /// 只能靠字号和色块,不能靠字重。显示层用 34pt 就是这么来的。
    enum Font {
        /// 显示层:bot 名、大标题。34pt,紧字距。
        static let display = SwiftUI.Font.system(size: 34, weight: .bold, design: .default)
        /// 次级标题。
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        /// 正文、字幕。
        static let body = SwiftUI.Font.system(size: 17, weight: .regular)
        /// 标签、状态词。**只在小尺寸用圆体** —— 整屏圆体会显幼。
        static let label = SwiftUI.Font.system(size: 13, weight: .medium, design: .rounded)
        /// 方块名这种极小字。
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium, design: .rounded)
        /// 数字(时长、计数),等宽防跳动。
        static let numeric = SwiftUI.Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
    }
}

// MARK: - 减弱动态效果

/// 「减弱动态效果」打开时用什么替代。
///
/// ## 为什么不是「把动画关掉」
///
/// 这个开关针对的是**前庭反应** —— 位移、缩放、回弹、旋转会让一部分人
/// 头晕甚至恶心。**淡入淡出不在其列**：Apple 自己的做法也是把位移类效果
/// 换成交叉淡化，而不是让界面瞬间跳变。
///
/// 全关掉反而更糟 —— 状态切换变成硬跳，看着像界面卡了一下。
///
/// 所以分两档：
/// - `ccAnimation` —— 弹簧、位移、缩放这类，减弱时**退化成淡出**
/// - `ccDecorativeAnimation` —— 无限循环的纯装饰（转圈、流光），减弱时**彻底停**
///
/// ⚠️ **判断标准是「这个动画有没有在传递信息」。** 转圈只说明"在忙"，
/// 停掉不丢信息；而音量柱的抖动本身就是信息，停掉等于把内容删了 ——
/// 那一类要单独想，不能顺手套这两个之一（见 `CCVoiceBars` 里的说明）。
private struct CCReduceMotion<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V
    /// 减弱时是彻底不动（装饰性），还是退化成淡出（状态切换）。
    let decorative: Bool

    func body(content: Content) -> some View {
        // 判定本身在 `CCMotionPolicy` 里（只依赖 Foundation，能离线测）。
        // 这里只负责把判定结果翻成一条 `Animation?` —— 这一层薄到没有出错空间，
        // 而那个 2×2 真值表是**写反了也看不出来**的，必须有测试钉着。
        let resolved: Animation? = switch CCMotionPolicy.resolve(
            reduceMotion: reduceMotion, decorative: decorative
        ) {
        case .still: nil
        case .fade: CC.Motion.fade
        case .asRequested: animation
        }
        return content.animation(resolved, value: value)
    }
}

extension View {
    /// 状态切换类动画。**新代码一律用这个，不要直接写 `.animation(_:value:)`。**
    ///
    /// 减弱动态效果打开时自动退化成淡出 —— 不用每个视图各自去读环境值，
    /// 也就不会再出现「加了个动画忘了 gate」这种只有特定用户才撞得到的漏网。
    func ccAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(CCReduceMotion(animation: animation, value: value, decorative: false))
    }

    /// 纯装饰的循环动画（流光之类）。减弱动态效果时**完全静止**。
    func ccDecorativeAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(CCReduceMotion(animation: animation, value: value, decorative: true))
    }
}

extension Shape where Self == RoundedRectangle {
    /// `.rect(cornerRadius:)` 的默认曲线不是 continuous，这里统一补上。
    static func cc(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}