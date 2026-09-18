import SwiftUI

/// 老电视开关机那个效果：从一条横线拉开，收的时候瘦回一条横线。
///
/// Chris 2026-09-18 定的：「一开始播的时候从一条线展开，播到结束以后把自己
/// 瘦成横着一条线结束。」
///
/// ## 为什么是 transition 不是 mask
///
/// 之前那版用的是 `.mask(Circle())` 配一个 `@SceneStorage` 的布尔 —— 只有
/// **进场**有动画，退场是直接消失。而这次要的恰恰是**退场那一下**：
/// 数字人说完话就没有新帧了，画面会僵在最后一帧上，Chris 明确说不要那张
/// 停止帧。`AnyTransition` 天生同时管进场和退场，正好是这个语义。
///
/// 还有一个实际差别：`@SceneStorage` 会跨启动记住，于是第二次进来时布尔已经
/// 是 true，`onAppear` 再设一次不产生变化 —— **动画一次都不播**。
/// transition 没有这种状态残留。
struct CCLineReveal: ViewModifier, Animatable {
    /// 0 = 一条横线，1 = 完全展开。
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            // 竖直压成线是主效果；横向同时收一点，收尾才像「吸回去」而不是
            // 「被门夹了」。0.004 不取 0：真到 0 有些渲染后端会整帧不画，
            // 那条亮线就看不见了。
            .scaleEffect(x: 0.55 + 0.45 * progress,
                         y: max(0.004, progress),
                         anchor: .center)
            // 最后一点点再淡出，免得那条线硬生生地「啪」一下没。
            .opacity(min(1, progress * 12))
    }
}

extension AnyTransition {
    /// 从一条横线展开 / 瘦回一条横线。
    static var ccLineReveal: AnyTransition {
        .modifier(active: CCLineReveal(progress: 0),
                  identity: CCLineReveal(progress: 1))
    }
}
