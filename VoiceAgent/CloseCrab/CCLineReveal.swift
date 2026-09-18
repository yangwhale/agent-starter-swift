import SwiftUI

/// 老式显像管开关机那个效果：横向「刺啦」一条亮线拉开，再慢慢撑成整屏；
/// 收的时候反过来 —— 先压成一条线，线再收掉。
///
/// Chris 2026-09-18 两次要求，第二次是关键的那次：
/// 「那个效果非常不好，看不出动画。就是那种刺啦一下子，然后慢慢展开。
/// 它展太快了，我都看不清这个过程，收的时候也是。」
///
/// ## 为什么第一版看不出来
///
/// 第一版是**一条线性缩放、450 ms 走完**。两个毛病叠在一起：
///
/// 1. **太快。** 450 ms 里同时发生「横向拉开」和「纵向撑开」，人眼只看到
///    画面「啪」地出现 —— 过程根本来不及被感知。
/// 2. **两个轴同时动，没有阶段感。** 显像管那个味道来自**先后**：
///    先横向炸开一条亮线（快），停顿感一下，再纵向缓缓展开（慢）。
///    两轴同步就退化成一个普通的缩放，像什么都没做。
///
/// 所以这一版把一个进度切成三段，各段做各自的事（见 `body`），
/// 总时长 `CCLineReveal.duration` = 1.1 s —— 慢到能看清，又不至于等。
///
/// ## 为什么是 ViewModifier + Animatable
///
/// 三段时序全靠**同一个 `progress` 驱动**。用多个 `@State` 分别延时触发也能做，
/// 但那样进场退场要各写一套，还得自己管取消 —— 而 `AnyTransition` 天生
/// 双向，倒着放就是收。**收不是另写的，是同一条曲线反过来跑。**
struct CCLineReveal: ViewModifier, Animatable {
    /// 0 = 完全收起（看不见），1 = 完全展开。
    var progress: Double

    /// 展开 / 收起的时长。**暴露出来给调用方设动画**，避免两处各写一个数 ——
    /// 不一致的话进场退场节奏会对不上，而那种不对劲很难指认。
    static let duration: Double = 1.1

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    // 三段的分界。命名而不是散落的魔数：调节奏时改这两个数就够。
    private static let flashEnd = 0.18      // 0…18%    横向炸开一条亮线
    private static let holdEnd = 0.30       // 18…30%   线亮着停一下

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)

        // 第一段：横向从一个点炸开成整条线。快 —— 这就是「刺啦」那一下。
        let lineSpread = min(p / Self.flashEnd, 1)
        // 第三段：纵向从线撑成整屏。慢，而且用 easeOut 让末尾更缓。
        let openRaw = max(0, (p - Self.holdEnd) / (1 - Self.holdEnd))
        let open = 1 - pow(1 - openRaw, 2.2)      // easeOut，尾巴拖得住

        return content
            // 纵向：0.004 不取 0 —— 真到 0 有些渲染后端整帧不画，那条亮线就没了。
            .scaleEffect(x: 0.04 + 0.96 * lineSpread,
                         y: max(0.004, open),
                         anchor: .center)
            // 那条线本身：展开过程中盖一层高光，越展开越淡。
            // 没有它的话「线」只是被压扁的画面，看不出是一道光。
            .overlay {
                GeometryReader { geo in
                    Rectangle()
                        .fill(.white)
                        .frame(height: 2)
                        .blur(radius: 3)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .opacity(lineSpread * (1 - openRaw) * 0.9)
                        .allowsHitTesting(false)
                }
            }
            // 整体淡入只在最开头那一小段做完，之后交给几何变化 ——
            // 全程淡入会把「展开」这件事糊掉。
            .opacity(min(1, p / 0.06))
    }
}

extension AnyTransition {
    /// 横线「刺啦」展开 / 收回。
    static var ccLineReveal: AnyTransition {
        .modifier(active: CCLineReveal(progress: 0),
                  identity: CCLineReveal(progress: 1))
    }
}
