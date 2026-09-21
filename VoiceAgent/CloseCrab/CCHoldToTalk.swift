import LiveKit
import SwiftUI

/// 「按住说话」长条 —— 控制栏正上方那一条。
///
/// ## 它不是对讲机
///
/// 这是**直播房间**：按下去就是开麦，声音一边说一边流过去；松手就是闭麦。
/// 没有「录一段 → 发送」这个动作，所以界面上**不许出现「发送」字样，
/// 也不许有录音时长** —— 那会让人以为松手之前对方听不见，于是说完还要等一下。
///
/// ## 为什么从「中间一大片」改成「底部一条」
///
/// 原来整个中间区域都是按住区，占了半个屏幕。问题是它用
/// `DragGesture(minimumDistance: 0)`，手指一落下就把手势吃掉了 ——
/// 而中间那片现在要用来左右滑动切 bot，两者在同一块区域上是互斥的。
///
/// 收成一条还有个附带好处：拇指够得着。半屏热区听着大方，实际按的时候
/// 手要往上抬，单手握持时很别扭。
///
/// ## 为什么用 DragGesture 而不是 onLongPressGesture
///
/// `onLongPressGesture` 的回调语义是「按够时长触发一次」+「按压状态变化」，
/// 想拿到干净的「按下→松开」两端其实很别扭，而且它自带一个最短时长，
/// 手快的时候会整个不触发 —— 表现是「我明明按了，怎么没开麦」。
///
/// `DragGesture(minimumDistance: 0)` 的 `onChanged` 在手指落下那一刻就来，
/// `onEnded` 在抬起那一刻来，正好是我们要的两端，而且**零延迟**。
/// 手指按住后小幅滑动也不会中断。
struct CCTalkBar: View {
    @EnvironmentObject private var localMedia: LocalMedia
    @Environment(CCMicPolicy.self) private var mic
    #if os(iOS) || os(visionOS)
    private var audio: CCAudioSessionPolicy { .shared }
    #endif

    /// 麦克风常开时这条不该还摆出「按住说话」的样子 —— 它此刻没作用。
    private var isAlwaysOn: Bool { localMedia.isMicrophoneEnabled && !mic.isHolding }

    /// **真的通了吗** —— 区别于「按下去了」。
    ///
    /// Chris 2026-09-20 定的：「点击开麦预热的这段时间我是能看出来的，
    /// 什么时候通了我才开始说话。」他说得对，但**原来的实现给不了这层保险**：
    /// 绿色和震动都挂在 `mic.isHolding` 上，而那个是在手指落下那一瞬间
    /// 同步置真的，`setMic(true)` 还没跑。绿灯亮 ≠ 麦通了。
    ///
    /// 判据取两条里更靠后的那个：
    /// - 轨道开了（`isMicrophoneEnabled`）—— 平台无关的底线
    /// - 引擎真的在采集（`CCAudioSessionPolicy.isCapturing`）—— 更接近事实，
    ///   但只有接管了音频会话时才有；开关关掉时它恒为 false，所以那种情况下
    ///   **不能**要求它，否则绿灯永远不亮。
    private var isLive: Bool {
        #if os(iOS) || os(visionOS)
        if CCAudioSessionPolicy.isEnabled { return localMedia.isMicrophoneEnabled && audio.isCapturing }
        #endif
        return localMedia.isMicrophoneEnabled
    }

    /// 按住了，但还没通。界面上要看得出来这一档 —— 它正是「先别说话」。
    private var isWarmingUp: Bool { mic.isHolding && !isLive }

    var body: some View {
        HStack(spacing: CC.Space.snug) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(verbatim: label)
                .font(CC.Font.title)
                .contentTransition(.numericText())
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: CC.Size.bar)
        // Liquid Glass 本体。`.interactive()` 让它在手指按下时自己产生
        // 折射和高光的形变 —— 这是系统按钮的那套反馈，自己用 scaleEffect
        // 模仿永远差一口气。
        //
        // ⚠️ **Mac 上换成纯色 ＋ 细线**（见 CCMacFlat）。状态还是靠颜色表达，
        //    只是从「玻璃染色」变成「填充色」—— 淡一点，因为 Mac 上
        //    一整条饱和色块会比手机上显得重得多。
        #if os(macOS)
            .ccFlatBar(radius: CC.Radius.bar, tint: macTint)
        #else
            .glassEffect(glass, in: .cc(CC.Radius.bar))
        #endif
        .overlay(alignment: .leading) { holdingPulse }
        .contentShape(.cc(CC.Radius.bar))
        .ccAnimation(CC.Motion.fade, value: mic.isHolding)
        .ccAnimation(CC.Motion.fade, value: isLive)
        .ccAnimation(CC.Motion.fade, value: isAlwaysOn)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in mic.beginHold(isMicrophoneEnabled: localMedia.isMicrophoneEnabled) }
                .onEnded { _ in mic.endHold() }
        )
        #if os(iOS)
        // ⭐ 震在**真的通了**那一下，不是手指落下那一下。
        //
        //    这一记就是「可以开口了」的信号 —— 提前震等于骗人，人会对着
        //    还没通的麦说话，第一个字丢掉。丢字当场看不出来，只能靠
        //    「说完发现没人回」发现，是最难查的那种。
        //
        //    松开时不震：闭麦晚 900 ms（给模型留判断「说完了」的静音，
        //    见 CCMicPolicy.releaseTailMs），那时候震反而对不上手的动作。
        //    走 CCHaptics 而不是 .sensoryFeedback，因为要认设置里那个
        //    「关掉震动」的开关。
        .onChange(of: isLive) { _, live in
            if live { CCHaptics.toggleMute() }
        }
        #endif
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - 样式

    /// 三个状态用**染色**区分，不用描边。
    ///
    /// 之前这里是一圈虚线框。虚线在 iOS 上有固定语义 —— 空占位、拖放目标、
    /// 未完成 —— 唯独不表示「可以按」。一个最主要的操作长得像占位符，
    /// 是这版界面最刺眼的一处。
    /// 待机那一档用 `.clear`，两个「开着麦」的状态仍然用 `.regular`。
    ///
    /// `.clear` 几乎只剩折射和边缘高光，背后的图能透过来 —— 这是这一条
    /// 大部分时间的样子，也是 Chris 说「玻璃效果不明显」指的那块。
    /// 但染色必须有底：`.clear.tint(.green)` 在亮背景上会淡到看不出，
    /// 而「麦还开着」是个漏了会尴尬的状态，不能为了好看牺牲它。
    private var glass: Glass {
        if isWarmingUp {
            // 按下了但还没通。**用黄色不用淡绿** —— 淡绿和满绿在余光里
            // 分不出来，而这两档的含义正好相反（先别说 / 可以说）。
            .regular.tint(.yellow).interactive()
        } else if mic.isHolding {
            .regular.tint(.green).interactive()
        } else if isAlwaysOn {
            // ⚠️ 原来是 `.green.opacity(0.5)`。**跟 Mac 那边同一个错** ——
            //    「已经开着」是个**已达成**的状态，不该画成半透明。
            //    淡色留给中间态（上面那档黄）。
            .regular.tint(.green).interactive()
        } else {
            .clear.interactive()
        }
    }

    #if os(macOS)
        /// Mac 上那条的填充色。
        ///
        /// ## ⛔ 上一版的饱和度是错的，而且错在**语义**上不是好看不好看
        ///
        /// 我按「实色填充要比玻璃染色淡」把三档全调淡了（0.35 / 0.30 / **0.15**）。
        /// Chris 2026-09-21 一眼看出问题：
        ///
        /// > 这种比较模糊的，是**中间状态**该有的，也就是在开麦的过程中。
        /// > 一旦打开了，就是**完全饱和的绿色**。
        ///
        /// 他说的是一条**通用的视觉语法**，不是这个 app 的偏好：
        /// **淡 ＝ 未完成 / 过渡；饱和 ＝ 已达成。**
        /// 我把「已经开着」画成了最淡的一档（0.15），
        /// 于是最确定的状态看起来最不确定 —— 正好反过来。
        ///
        /// ⚠️ 而且它还带了个可读性 bug：0.15 的绿上面压**白字**，
        /// 基本读不出来（截图里就是这样）。
        /// **降饱和这件事不能只看填充，要连着前景色一起算对比度。**
        ///
        /// 现在的映射：
        ///   接通中   → 黄，中等饱和（**这一档才该是"模糊"的**）＋ 黑字
        ///   按住说话 → 饱和绿 ＋ 白字
        ///   麦克风常开 → 饱和绿 ＋ 白字（**跟按住同档** —— 两者都是"麦开着"，
        ///                区别由文案说，不由颜色说）
        private var macTint: Color? {
            if isWarmingUp { return .yellow.opacity(0.55) }
            if mic.isHolding { return .ccSpeaking }
            if isAlwaysOn { return .ccSpeaking }
            return nil          // 待机＝系统控件底色
        }
    #endif

    private var foreground: Color {
        // 黄底上用黑字。白字在黄色上读不清，而这一档要传达的恰恰是
        // 「**先别说**」—— 看不清就等于没说。
        if isWarmingUp { return .black }
        return mic.isHolding || isAlwaysOn ? .white : .primary
    }

    private var icon: String {
        if isWarmingUp { "hourglass" }
        else if mic.isHolding { "waveform" }
        else if isAlwaysOn { "mic.fill" }
        else { "mic.slash.fill" }
    }

    private var label: String {
        if isWarmingUp { "接通中，先别说" }
        else if mic.isHolding { "松开结束" }
        else if isAlwaysOn { "麦克风常开中" }
        else { "按住说话" }
    }

    /// 按住时左边那颗呼吸的点。
    ///
    /// 光靠变色不够 —— 绿色在余光里和灰色区分度没想象中大，而「麦还开着」
    /// 是个漏了会尴尬的状态。一个动的东西在余光里永远比一块静止的颜色显眼。
    @ViewBuilder
    private var holdingPulse: some View {
        if mic.isHolding, isLive {
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
                .padding(.leading, CC.Space.regular)
                .symbolEffect(.pulse)
                .transition(.scale.combined(with: .opacity))
        }
    }
}
