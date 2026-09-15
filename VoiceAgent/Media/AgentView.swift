import LiveKitComponents

/// A view that combines the avatar camera view (if available)
/// or the audio visualizer (if available).
/// - Note: If both are unavailable, the view will show a placeholder visualizer.
struct AgentView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var rooms: CCRooms

    @Environment(\.namespace) private var namespace
    /// Reveals the avatar camera view when true.
    @SceneStorage("videoTransition") private var videoTransition = false

    var body: some View {
        ZStack {
            if let avatarVideoTrack = session.agent.avatarVideoTrack {
                SwiftUIVideoView(avatarVideoTrack)
                    .clipShape(RoundedRectangle(cornerRadius: .cornerRadiusPerPlatform))
                    .aspectRatio(avatarVideoTrack.aspectRatio, contentMode: .fit)
                    .padding(.horizontal, session.agent.avatarVideoTrack?.aspectRatio == 1 ? 4 * .grid : .zero)
                    .shadow(radius: 20, y: 10)
                    .mask(
                        GeometryReader { proxy in
                            let targetSize = max(proxy.size.width, proxy.size.height)
                            Circle()
                                .frame(width: videoTransition ? targetSize : 6 * .grid)
                                .position(x: 0.5 * proxy.size.width, y: 0.5 * proxy.size.height)
                                .scaleEffect(2)
                                .animation(.smooth(duration: 1.5), value: videoTransition)
                        }
                    )
                    .onAppear {
                        videoTransition = true
                    }
            } else if session.isConnected {
                VStack(spacing: CC.Space.loose) {
                    metallicBars
                    // 可视化能表达「设备活着」,但表达不了「轮到你说了」。
                    // 语音交互最大的困惑就是这个,用一个词解决的成本远低于用动画。
                    Text(verbatim: stateHint)
                        .font(CC.Font.label)
                        .foregroundStyle(.fg2)
                        .contentTransition(.numericText())
                        .animation(CC.Motion.fade, value: stateHint)
                }
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: session.agent.audioTrack?.id)
        .matchedGeometryEffect(id: "agent", in: namespace!)
    }

    // MARK: - 柱状图

    /// SDK 的柱状图，但填的是金属而不是一块纯色。
    ///
    /// ## 之前为什么看着是「五个点点」
    ///
    /// 组件本身一直是 `BarAudioVisualizer`，没换过。问题出在**宽度**：
    /// 之前给的是 `maxWidth: 75 * .grid` ＝ 300pt，五根柱子每根就是 60pt 宽。
    /// 而柱子是胶囊形、圆角等于宽度的一半，安静时高度收到最低（≈直径），
    /// 于是五根柱子变成五个直径 60pt 的大圆点。
    ///
    /// 收到 168pt 之后每根约 27pt 宽，安静时是小圆点、一说话就抽成长条，
    /// 这才是 LiveKit 那个柱状图本来的样子。**这是一个尺寸问题，不是组件问题。**
    ///
    /// ## 金属是怎么填进去的
    ///
    /// `BarAudioVisualizer` 只收一个 `barColor: Color`，喂不进渐变。
    /// 所以反过来用：让它画**纯白**柱子，再拿这堆柱子给金属渐变做遮罩 ——
    /// 白的地方露出金属，其余透明。
    ///
    /// 附带一个好处：`barMinOpacity` 于是有了额外含义 —— 安静的那几根遮罩不满，
    /// 金属跟着淡下去，比整排一样亮更像真的在响。
    private var metallicBars: some View {
        let identity = CCIdentityColor.color(for: rooms.activeName)
        return metal(identity)
            .mask {
                BarAudioVisualizer(
                    audioTrack: session.agent.audioTrack,
                    barColor: .white,
                    barCount: 5,
                    barSpacingFactor: 0.22,
                    barMinOpacity: 0.26
                )
                // **这行不能省。** 组件在 init 里把 track 捕获进 `@StateObject`，
                // 而 `StateObject(wrappedValue:)` 的闭包只求值一次。
                // agent 的音轨是连上之后才出现的，第一次构造时是 nil ——
                // 不换视图身份它就永远绑在 nil 上，柱子是死的。
                // 上游 ControlBar 里那句 `.id(localMedia.microphoneTrack?.id)`
                // 解的是同一个问题。
                .id(session.agent.audioTrack?.id)
            }
            .frame(width: 168, height: 190)
            // 两层辉光。柱子本身是被遮罩切出来的，shadow 跟着 alpha 走，
            // 所以光是从每根柱子的实际形状散出来的，不是一个方块的外发光。
            .shadow(color: identity.opacity(0.55), radius: 18)
            .shadow(color: identity.opacity(0.28), radius: 40)
    }

    /// 金属质感 = **多段明暗交替的纵向渐变** ＋ 一道斜向高光。
    ///
    /// 单向渐变（上亮下暗）只会得到「塑料」。金属之所以像金属，是因为它把
    /// 环境里的亮带和暗带一起反射进来，所以纵向上必须**亮—暗—亮—暗**地跳，
    /// 而不是单调地过渡。斜向那道是高光扫过的痕迹，用 `plusLighter` 叠加，
    /// 只提亮不改色相。
    private func metal(_ base: Color) -> some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.95), location: 0.00),
                    .init(color: base.opacity(0.80), location: 0.14),
                    .init(color: base, location: 0.34),
                    .init(color: .white.opacity(0.88), location: 0.50),
                    .init(color: base, location: 0.64),
                    .init(color: base.opacity(0.55), location: 0.82),
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
        // 切 bot 时金属的颜色要过渡，不要硬切 —— 硬切看着像闪了一下。
        .animation(.easeInOut(duration: 0.5), value: base)
    }

    private var stateHint: String {
        switch session.agent.agentState {
        case .speaking: "它在说"
        case .thinking: "在想…"
        case .listening: "在听,说吧"
        case .initializing: "接通中…"
        default: session.agent.isConnected ? "在听,说吧" : "助理还没上线"
        }
    }
}
