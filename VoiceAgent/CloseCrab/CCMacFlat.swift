#if os(macOS)

    import AppKit
    import SwiftUI

    /// Mac 的面板表面：**纯色 ＋ 1px 细线**。取代 iOS 那一套 Liquid Glass。
    ///
    /// ## 为什么 Mac 上不能用玻璃
    ///
    /// Chris 2026-09-21，对着飞书 Mac 版：
    ///
    /// > 在 macOS 上它也没有那个 Liquid Glass，所以你并不需要一个图片当背景，
    /// > 就是纯纯色的，这样才符合其他应用的设计范式。
    ///
    /// 这不是审美偏好，是两层事实：
    ///
    /// 1. **Mac 的应用窗口没有 Liquid Glass 这套语言。** iOS 26 把玻璃用在
    ///    悬浮控件上，因为手机界面是「内容满屏 ＋ 控件浮在上面」。
    ///    Mac 是「窗口分栏 ＋ 每栏是实心面板」，栏与栏之间靠 **1px 分隔线**
    ///    区分，不靠材质。摆一堆玻璃进去，出来的是「一个跨平台 app」。
    ///
    /// 2. **玻璃背后没东西可折射就退化成灰块。** 这条这个工程自己的注释里
    ///    就写过：「背后是一块纯色的话，折射没东西可弯，出来就是个扁平的带色方块」。
    ///    所以**去掉背景图和去掉玻璃必须一起做** —— 只去掉背景图，
    ///    剩下的就是一堆灰方块，比原来更难看。
    ///
    /// ## 用系统语义色，不要自己调
    ///
    /// `windowBackgroundColor` / `controlBackgroundColor` / `separatorColor`
    /// 会跟着深浅色、跟着「提高对比度」「减少透明度」这些辅助功能开关变。
    /// 自己写死一个十六进制，在那些设置下就跟系统控件对不上 ——
    /// 而「跟旁边的系统控件颜色差一点点」恰恰是最容易被看出来不原生的地方。
    extension View {
        /// 圆角矩形面板（说话条、控制栏这一类）。
        func ccFlatBar(radius: CGFloat, tint: Color? = nil) -> some View {
            modifier(CCFlat(shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                            tint: tint))
        }

        /// 胶囊（控制栏里单颗按钮）。
        func ccFlatCapsule(tint: Color? = nil) -> some View {
            modifier(CCFlat(shape: Capsule(), tint: tint))
        }

        /// 圆形。
        func ccFlatCircle(tint: Color? = nil) -> some View {
            modifier(CCFlat(shape: Circle(), tint: tint))
        }
    }

    /// 三个入口共用的实现。**故意写成具体形状的三个函数而不是一个泛型** ——
    /// `.capsule` / `.circle` 这些简写是声明在 `Shape` 上的，
    /// 传进 `some InsettableShape` 参数时不一定解析得到（同一族的坑今天撞过一次：
    /// `ShapeStyle` 上没有 `ccSpeaking`）。三个具体函数没有这个风险。
    private struct CCFlat<S: InsettableShape>: ViewModifier {
        let shape: S
        let tint: Color?

        func body(content: Content) -> some View {
            content
                .background(tint ?? Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay {
                    // **1px，不是 1.5pt。** Mac 的分隔线就是一个物理像素那么细，
                    // 粗一点点整屏就「重」起来了 —— 这是飞书那张图上
                    // 最明显但最说不出来的差别。
                    shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }
    }

    /// 窗口底色。**用系统的，不要自己铺图。**
    enum CCMacSurface {
        /// 整个窗口的底。
        static var window: Color { Color(nsColor: .windowBackgroundColor) }
        /// 内容面板（比窗口底稍亮/稍暗，取决于深浅色）。
        static var panel: Color { Color(nsColor: .controlBackgroundColor) }
        /// 1px 分隔线。
        static var separator: Color { Color(nsColor: .separatorColor) }
    }

#endif
