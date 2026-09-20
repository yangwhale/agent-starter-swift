@preconcurrency import AVFoundation
import Observation
import LiveKit
import SwiftUI

/// 自己接的音频表头 ＋ 柱状图。**替掉 SDK 的 `BarAudioVisualizer`。**
///
/// ## 为什么不用 SDK 那个
///
/// 它一直在界面上，但柱子从来没立起来过 —— 五个圆点纹丝不动。
/// 扒了 `components-swift 0.1.7` 的源码之后，事情很清楚：
///
/// ```swift
/// height = (H - barMinHeight) * bands[index] + barMinHeight
/// ```
///
/// 柱子的高度**只有一个来源**：`AudioProcessor.bands`。而 `bands` 只在
/// `render(pcmBuffer:)` 被音频线程回调时才更新。它内部那套 `agentState`
/// 动画（listening 时中间那根呼吸、thinking 时挨个扫过去）**只改 opacity，
/// 一个像素的高度都不改**。
///
/// 也就是说：只要一帧音频都没收到，它在任何状态下都只能是一排等高的圆点，
/// 而且**不会有任何迹象表明它没收到音频** —— 这是一个完全静默的失败。
///
/// 上一版我以为是柱子太胖（300pt 配 5 根 ＝ 每根 60pt，圆角等于宽度一半，
/// 静止时正好是圆）。宽度确实有问题，但那只解释了「为什么是圆的」，
/// 没解释「为什么不动」。**两个问题，我只修了次要的那个。**
///
/// ## 这一版做了三件事
///
/// 1. **自己挂一个 `AudioRenderer` 到音轨上**，算 RMS。不用 FFT ——
///    我们要的是「在说话」这个信息，不是频谱分析仪。少一层就少一处会静默失败。
/// 2. **把收到多少帧记下来并显示出来**（排障开关打开时）。
///    静默失败最贵的地方是你不知道它失败了，这一步比修 bug 本身更重要。
/// 3. **收不到帧时跑兜底动画**。`agentState` 我们知道是准的（那行状态提示
///    一直在变），所以哪怕音频这条路是断的，「它在说话」这件事仍然能表达出来。
///    用不用兜底会写在排障那行里，不会假装一切正常。
@MainActor
@Observable
final class CCVoiceMeter: AudioRenderer {
    /// 每根柱子当前的高度系数，0–1。
    private(set) var levels: [Float]

    /// 一共收到过多少个音频缓冲。**柱子不动时第一个该看的数。**
    /// 它一直是 0 ＝ 音轨那头就没通，跟界面无关。
    private(set) var frames: Int = 0

    /// 现在跑的是不是兜底动画。
    private(set) var isFallback = false

    let barCount: Int

    /// 当前挂着的所有音轨。
    ///
    /// **是数组不是一条**：一个房间里有两个会出声的东西 —— Gemini 语音助手，
    /// 和 bot 本体播报结论的那条旁路。哪条在响是运行时才知道的，所以两条都量，
    /// 取最大值（见 `ingest`）。只挂 `session.agent.audioTrack` 的话，
    /// bot 本体说话时柱子一动不动 —— 那路声音压根不在那条轨上。
    ///
    /// 持有的是强引用：轨那头只弱引用我们（`MulticastDelegate` 用 `NSHashTable`），
    /// 不构成环。`detach()` 会清干净。
    private var attached: [any AudioTrack] = []
    private var pump: Task<Void, Never>?
    /// 最近一次算出来的电平，等泵去消费。
    private var incoming: Float = 0
    private var isSpeaking = false
    private var phase: Double = 0

    init(barCount: Int = 5) {
        self.barCount = barCount
        levels = Array(repeating: 0, count: barCount)
    }

    // MARK: - 接上 / 断开

    /// 换音轨时调。传空数组 ＝ 只断开。
    func attach(_ tracks: [any AudioTrack]) {
        detach()
        guard !tracks.isEmpty else { return }
        attached = tracks
        for track in tracks { track.add(audioRenderer: self) }
        frames = 0
        isFallback = false
        startPump()
    }

    func detach() {
        pump?.cancel()
        pump = nil
        for track in attached { track.remove(audioRenderer: self) }
        attached = []
        incoming = 0
    }

    func setSpeaking(_ speaking: Bool) {
        isSpeaking = speaking
        if speaking, pump == nil { startPump() }
    }

    // MARK: - 泵

    /// 30fps 把电平推进柱子里。
    ///
    /// **不在 `render` 里直接改 `levels`。** 音频回调是每 10ms 一次、在音频线程上，
    /// 每次都跳一趟主线程改 `levels` 会让 SwiftUI 一秒重绘一百次，
    /// 而屏幕只有 60Hz。泵把两边解耦：音频那头只管往 `incoming` 里塞最新值。
    private func startPump() {
        pump?.cancel()
        pump = Task { [weak self] in
            while !Task.isCancelled {
                self?.step()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func step() {
        // 说着话却一帧没收到 —— 音频那条路是断的，切兜底。
        // 判据用 `frames == 0` 而不是「最近没收到帧」：后者在正常的静音段
        // 也成立，会让柱子在说话间隙乱抖。
        let shouldFallback = isSpeaking && frames == 0
        if shouldFallback != isFallback { isFallback = shouldFallback }

        let drive: Float
        if isFallback {
            phase += 0.16
            // 两个不同频率的正弦叠加，避免机械的匀速起伏。
            let a = abs(sin(phase))
            let b = abs(sin(phase * 1.73 + 0.9))
            drive = Float(0.30 + 0.55 * (a * 0.6 + b * 0.4))
        } else {
            drive = incoming
            // 没有新帧就自然衰减，别停在半空。
            incoming *= 0.80
        }

        let center = barCount / 2
        var next = levels
        next[center] += (drive - next[center]) * 0.5

        // 外侧的柱子追**上一帧**的内侧邻居 —— 读 `levels` 而不是 `next`。
        // 读 `next` 的话整排会在同一帧内一起到位，看着像整体伸缩；
        // 读上一帧才有「从中间往外扩」的传播感。
        var left = center - 1
        var right = center + 1
        while left >= 0 || right < barCount {
            if left >= 0 {
                next[left] += (levels[left + 1] * 0.80 - next[left]) * 0.40
                left -= 1
            }
            if right < barCount {
                next[right] += (levels[right - 1] * 0.80 - next[right]) * 0.40
                right += 1
            }
        }
        levels = next.map { min(max($0, 0), 1) }
    }

    // MARK: - 电平

    fileprivate func ingest(_ level: Float) {
        frames &+= 1
        // 取大的那个：波峰要立刻上去，回落交给衰减。
        // 反过来做的话，一个安静的缓冲就能把刚起来的柱子按回去，整排会闪。
        incoming = max(incoming, level)
    }
}

// MARK: - 音频回调

extension CCVoiceMeter {
    /// 在**音频线程**上被调用。这里只做算术，不碰任何 UI 状态。
    nonisolated func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let level = Self.level(of: pcmBuffer) else { return }
        Task { @MainActor [weak self] in self?.ingest(level) }
    }

    /// RMS → 0–1。
    ///
    /// **两种采样格式都要处理。** WebRTC 这条链路上拿到的既可能是 float32
    /// 也可能是 int16，只判一种的话在另一半设备上就是一排不动的柱子 ——
    /// 而且照样没有任何报错。
    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float? {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }

        // **所有声道一起算。** SDK 2.17 起订阅端会协商 Opus stereo
        // （2.16 一律降混成单声道），所以自定义 renderer 拿到的可能是双声道。
        // 只读 channel[0] 的话，如果人声偏在右声道，柱子就是一排不动的 ——
        // 而且不会有任何报错。
        let channels = max(Int(buffer.format.channelCount), 1)
        var sum: Float = 0
        if let floats = buffer.floatChannelData {
            for c in 0 ..< channels {
                let channel = floats[c]
                for i in 0 ..< count { sum += channel[i] * channel[i] }
            }
        } else if let ints = buffer.int16ChannelData {
            for c in 0 ..< channels {
                let channel = ints[c]
                for i in 0 ..< count {
                    let v = Float(channel[i]) / 32768
                    sum += v * v
                }
            }
        } else {
            return nil
        }

        let rms = (sum / Float(count * channels)).squareRoot()
        // -50dB ~ 0dB 映射到 0 ~ 1。人声正常说话大概落在 -30 ~ -10dB，
        // 取 -50 做地板是为了让轻声也能看出动静，同时把底噪压在 0 附近。
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 50) / 50, 0), 1)
    }
}

// MARK: - 柱子

/// 金属柱状图。
struct CCVoiceBars: View {
    @Environment(\.colorScheme) private var scheme
    /// 房间里**所有**会出声的 bot 音轨 —— 语音助手的 ＋ 本体旁路的。
    /// 只给一条的话，bot 查完东西播报结论时柱子不会动（那是另一条轨）。
    let tracks: [any AudioTrack]
    let isSpeaking: Bool
    let tint: Color
    /// 排障开关打开时，在柱子底下显示收了多少帧、是不是在跑兜底。
    var showsDebug: Bool = false

    @State private var meter = CCVoiceMeter(barCount: 5)

    /// 静止时的高度 ＝ 柱子宽度，于是是个圆点；一说话就抽成长条。
    /// 方块上那个小版本会把这三个都调小（见 `CCRoomTileRow`）。
    var barWidth: CGFloat = 22
    var spacing: CGFloat = 12
    var maxHeight: CGFloat = 190
    /// 辉光半径。小尺寸下要按比例收，不然一个 22pt 的波形拖着 40pt 的光晕。
    var glow: CGFloat = 1

    var body: some View {
        VStack(spacing: CC.Space.snug) {
            metal
                .mask { bars }
                .frame(width: CGFloat(meter.barCount) * barWidth + CGFloat(meter.barCount - 1) * spacing,
                       height: maxHeight)
                // 辉光跟着遮罩的 alpha 走，所以是从每根柱子的实际形状散出来的，
                // 不是一个方块的外发光。
                // 先落一道**暗向**的接触阴影，再叠辉光。
                //
                // 之前只有 tint 辉光：柱子本身是白色金属渐变，浅色模式下
                // 压在亮背景（云图）上等于白压白，五根柱子直接消失 ——
                // 而且因为它还在动，你甚至不会觉得是"坏了"，只会觉得"没东西"。
                // 辉光救不了这个：辉光是加亮，亮背景上加亮＝更看不见。
                // 需要的是一道往下沉的暗边，把柱子从背景里抠出来。
                .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.34),
                        radius: 3, y: 1)
                .shadow(color: tint.opacity(0.55), radius: 18 * glow)
                .shadow(color: tint.opacity(0.28), radius: 40 * glow)

            if showsDebug { debugLine }
        }
        // 音轨是连上之后才出现的，**必须换了就重新挂** ——
        // 这正是 SDK 那个组件栽的地方：它在 init 里把音轨捕进 @StateObject，
        // 而 StateObject 的闭包只求值一次，第一次是 nil 就永远是 nil。
        // 我们把「挂载」从 init 里拿出来变成一个显式动作，这个坑就不存在了。
        //
        // 盯的是**拼起来的 id 串**而不是数组本身：`[any AudioTrack]` 不是
        // Equatable，`onChange` 收不了；而且轨的增删（本体旁路中途进房）
        // 正是要重挂的时机，id 串能如实反映这件事。
        .onChange(of: trackKey, initial: true) { _, _ in meter.attach(tracks) }
        .onChange(of: isSpeaking, initial: true) { _, speaking in meter.setSpeaking(speaking) }
        .onDisappear { meter.detach() }
        // ## 对 VoiceOver 隐藏，但信息没丢
        //
        // 柱子是**自绘图形**，无障碍树里它没有名字 —— 不处理的话
        // VoiceOver 划到这儿只会停在一块沉默的东西上。
        //
        // 而它传递的「在不在说话」两处都已经有文字承载：
        // 大的那个底下就是 `AgentView` 的状态提示（"它在说" / "在听,说吧"），
        // 方块上那个由 `CCRoomTileRow` 的标签念出圈的状态。
        // **重复念一遍不是更无障碍，是更吵。**
        //
        // ⚠️ 哪天这两处文字被拿掉了，这一行要跟着改成真标签，不能就这么留着。
        .accessibilityHidden(true)
    }

    /// 挂了哪几条轨的指纹。排序过 —— 参与者字典的遍历顺序不保证稳定，
    /// 不排的话同一批轨可能每次算出不同的串，白白重挂。
    private var trackKey: String {
        tracks.map(\.id).sorted().joined(separator: ",")
    }

    private var bars: some View {
        HStack(spacing: spacing) {
            ForEach(0 ..< meter.barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(.white)
                    .frame(width: barWidth, height: height(index))
            }
        }
        .frame(height: maxHeight)
        // 泵是 30fps，动画只需要把两帧之间抹平，时长跟泵的间隔对齐。
        // 给长了会拖尾，给 spring 会因为每帧都在改目标值而抖。
        //
        // ⚠️ **这一处是故意不走 `ccAnimation` 的**，别顺手改。
        //
        // 「减弱动态效果」针对的是前庭反应，而柱子的起伏**本身就是内容** ——
        // 说没说话、说得急还是缓，全在这上面。停掉等于把信息删了，
        // 不是「少一个动效」。
        //
        // 而且去掉这 33ms 插值只会**更差**：泵是 30fps，不抹平两帧之间，
        // 柱子变成一格一格硬跳，视觉上比平滑起伏更刺激。
        // 真要照顾这类用户，正确方向是给一个「不显示波形」的开关，
        // 而不是把动画拆掉留一个抽搐的波形。
        .animation(.linear(duration: 0.033), value: meter.levels)
    }

    private func height(_ index: Int) -> CGFloat {
        let level = CGFloat(meter.levels.indices.contains(index) ? meter.levels[index] : 0)
        return barWidth + (maxHeight - barWidth) * level
    }

    /// 金属 ＝ 纵向亮暗亮暗多段跳 ＋ 一道斜向高光。
    /// 单向渐变（上亮下暗）只会得到塑料：金属像金属，是因为它把环境里的
    /// 亮带和暗带一起反射进来。
    private var metal: some View {
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

    /// 排障那一行。**这行是这次改动里最该留的东西。**
    ///
    /// 「柱子不动」有两种完全不同的原因，肉眼一模一样：
    /// 音轨没接上（帧数恒为 0），还是接上了但对面没出声（帧数在涨、电平很低）。
    /// 有了这行，下次十秒就能分清，不用再扒一遍 SDK 源码。
    private var debugLine: some View {
        Text(verbatim: meter.isFallback
            ? "音频帧 \(meter.frames) · 兜底动画（音轨没通）"
            : "音频帧 \(meter.frames) · 实时")
            .font(CC.Font.numeric)
            .foregroundStyle(meter.isFallback ? .fgSerious : .fg3)
    }
}
