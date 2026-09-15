import LiveKitComponents

/// A view that combines the avatar camera view (if available)
/// or the audio visualizer (if available).
/// - Note: If both are unavailable, the view will show a placeholder visualizer.
struct AgentView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var rooms: CCRooms
    /// 只为「显示网络读数」那个排障开关订阅 —— 它同时控制柱子底下那行帧数。
    @ObservedObject private var config = CloseCrabConfig.shared

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
                    voiceBars
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

    /// 中间那排柱子。实现在 `CCVoiceBars`，**不再用 SDK 的 `BarAudioVisualizer`**。
    ///
    /// 换掉的原因写在 `CCVoiceBars` 的文档注释里，一句话版本：
    /// 那个组件的柱子高度**只有一个来源**（`AudioProcessor.bands`），
    /// 一帧音频都收不到时它在任何状态下都只能是一排等高的圆点，
    /// 而且不会有任何迹象说明它没收到音频 —— 是个完全静默的失败。
    ///
    /// `isSpeaking` 单独传进去：音频那条路万一是断的，`agentState` 仍然是准的
    /// （这行状态提示一直在变就是证据），可以拿它跑兜底动画。
    private var voiceBars: some View {
        CCVoiceBars(
            tracks: session.ccBotAudioTracks,
            isSpeaking: session.ccIsSpeaking,
            tint: CCIdentityColor.color(for: rooms.activeName),
            showsDebug: config.netReadout
        )
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
