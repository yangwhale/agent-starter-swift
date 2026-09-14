import LiveKit
import LiveKitComponents
import SwiftUI

/// agent 的声音可视化:一团会呼吸、会思考、会被声音撑开形变的液体。
///
/// ## 为什么必须换掉原来那个
///
/// 原来是 `BarAudioVisualizer(barCount: 5, barMinOpacity: 0.1)`。看组件源码:
///
/// ```swift
/// let barMinHeight = barWidth        // 最小高度 = 条宽
/// height = (H - barMinHeight) * bands[i] + barMinHeight
/// cornerRadius = 100                 // 全圆角
/// ```
///
/// 音量为 0 时,高度 = 宽度 + 全圆角 = **正圆**。于是静止态就是
/// 五个不透明度 0.1 的灰圆点 —— 和「渲染失败」长得一模一样。
/// 这不是配色能救的,必须换形态。
///
/// ## 三条设计原则
///
/// 1. **静止态不能是「最小值」,必须是另一种活着的状态。** 柱状图把「没声音」
///    映射成「最矮」,而最矮长得像坏掉。所以 `listening` 有自己独立的、
///    不依赖音频数据的呼吸动画。
/// 2. **四个状态要靠形态区分,不只是速度。** 原来 idle/listening/thinking/speaking
///    只有动画时长不同(2/n、0.5、0.15、极长),用户根本感知不到。
/// 3. **不要用 5 这个数字。** 5 是柱状图的尴尬数量 —— 多到不像一个整体,
///    少到不像频谱。这里用 1(一团)。
struct CCLiquidOrb: View {
    let track: AudioTrack?
    let state: AgentState
    /// 当前 bot 的身份色,液体的主色调。
    let tint: Color

    /// 24 段频谱。够画出圆润的轮廓,又不至于变成锯齿。
    @StateObject private var audio: AudioProcessor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false
    @State private var spin = false

    init(track: AudioTrack?, state: AgentState, tint: Color) {
        self.track = track
        self.state = state
        self.tint = tint
        _audio = StateObject(wrappedValue: AudioProcessor(
            track: track,
            bandCount: 24,
            isCentered: false,
            smoothingFactor: 0.35
        ))
    }

    var body: some View {
        ZStack {
            glow
            body_
            highlight
        }
        .frame(width: 240, height: 240)
        .animation(.easeInOut(duration: 0.35), value: state)
        .onAppear {
            breathe = true
            spin = true
        }
        .accessibilityLabel(Text(verbatim: stateLabel))
    }

    // MARK: - 三层

    /// 外圈辉光。声音越大扩得越开 —— 它是「这个房间有声音」在余光里的信号。
    private var glow: some View {
        CCOrbShape(bands: bands, wobble: wobblePhase)
            .fill(tint)
            .blur(radius: 38)
            .opacity(state == .speaking ? 0.55 : 0.28)
            .scaleEffect(breathScale * 1.06)
    }

    /// 液体本体。
    private var body_: some View {
        CCOrbShape(bands: bands, wobble: wobblePhase)
            .fill(
                // 角度渐变 + 自转,让它看着像有厚度的液体而不是一块色片。
                AngularGradient(
                    colors: [tint, .fgAccent2, tint.opacity(0.75), tint],
                    center: .center,
                    angle: .degrees(spin && !reduceMotion ? 360 : 0)
                )
            )
            .overlay(
                CCOrbShape(bands: bands, wobble: wobblePhase)
                    .stroke(.white.opacity(0.28), lineWidth: 1)
            )
            .scaleEffect(breathScale)
            .animation(
                reduceMotion ? nil : .linear(duration: 18).repeatForever(autoreverses: false),
                value: spin
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 2.2).repeatForever(autoreverses: true),
                value: breathe
            )
            .opacity(state == .idle ? 0.35 : 1)
    }

    /// 高光。固定在左上,给液体一个光源方向 —— 没有它就是一坨平的色块。
    private var highlight: some View {
        Ellipse()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.55), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 78, height: 54)
            .rotationEffect(.degrees(-22))
            .offset(x: -42, y: -52)
            .blur(radius: 9)
            .scaleEffect(breathScale)
            .opacity(state == .idle ? 0 : 1)
    }

    // MARK: - 形变数据

    /// 喂给轮廓的 24 个半径偏移量。
    ///
    /// **只有 `speaking` 用真实频谱** —— 其余状态用程序生成的形变。
    /// 这是原则 1 的落点:没声音的时候它不是「振幅为 0」,而是在做别的事。
    private var bands: [CGFloat] {
        switch state {
        case .speaking:
            audio.bands.map { CGFloat($0) }
        case .thinking:
            // 不规律的起伏,像在翻找东西。用两个不同频率的正弦叠加,
            // 避免出现肉眼能数出来的周期。
            (0 ..< 24).map { i in
                let t = wobblePhase
                let a = sin(Double(i) * 0.8 + t * 3.1) * 0.5
                let b = sin(Double(i) * 0.31 - t * 1.7) * 0.5
                return CGFloat(max(0, (a + b) * 0.5 + 0.22))
            }
        default:
            // listening / idle:近似正圆,只留一点极缓的起伏,
            // 让它看着是活的液体而不是一个几何圆。
            (0 ..< 24).map { i in
                CGFloat(0.10 + 0.05 * sin(Double(i) * 0.5 + wobblePhase))
            }
        }
    }

    private var breathScale: CGFloat {
        guard !reduceMotion else { return 1 }
        return breathe && state != .idle ? 1.045 : 1
    }

    /// 形变相位。用 `TimelineView` 会更准,但那意味着整棵子树每帧重建;
    /// 这里用时间取模够了 —— 形变本身是模糊的,差几毫秒没人看得出。
    private var wobblePhase: Double {
        reduceMotion ? 0 : Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000)
    }

    private var stateLabel: String {
        switch state {
        case .speaking: "助理正在说话"
        case .thinking: "助理正在思考"
        case .listening: "助理在听"
        default: "助理未在线"
        }
    }
}

/// 极坐标下的闭合曲线:`r(θ) = R × (1 + band[θ] × 强度)`。
///
/// 用 Catmull-Rom 式的平滑(这里用二次贝塞尔的中点近似)把 24 个采样点连成
/// 圆润曲线 —— 直接 `addLine` 会得到一个 24 边形,声音一大就是个多边形抖动,
/// 那比柱状图还难看。
struct CCOrbShape: Shape {
    var bands: [CGFloat]
    var wobble: Double

    var animatableData: Double {
        get { wobble }
        set { wobble = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let base = min(rect.width, rect.height) * 0.33
        let count = max(bands.count, 8)

        // 采样点:半径被频谱撑开。0.55 是形变强度,再大就会出现自交的尖刺。
        //
        // 这段刻意写得啰嗦、每步都标类型:写成一行链式表达式时
        // Swift 的类型检查器会在 CGFloat/Double 的重载上爆炸
        // (error: unable to type-check this expression in reasonable time)。
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for index in 0 ..< count {
            let ratio: Double = Double(index) / Double(count)
            let angle: Double = ratio * 2 * Double.pi - Double.pi / 2
            let amplitude: CGFloat = index < bands.count ? bands[index] : 0
            let radius: CGFloat = base * (1 + amplitude * 0.55)
            let x: CGFloat = center.x + CGFloat(cos(angle)) * radius
            let y: CGFloat = center.y + CGFloat(sin(angle)) * radius
            points.append(CGPoint(x: x, y: y))
        }

        var path = Path()
        guard points.count > 2 else { return path }

        // 从相邻两点的中点起笔,把原采样点当控制点 —— 这样曲线必然平滑闭合,
        // 不需要额外处理首尾接缝。
        let mid = { (a: CGPoint, b: CGPoint) in
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        path.move(to: mid(points[points.count - 1], points[0]))
        for i in 0 ..< points.count {
            let current = points[i]
            let next = points[(i + 1) % points.count]
            path.addQuadCurve(to: mid(current, next), control: current)
        }
        path.closeSubpath()
        return path
    }
}
