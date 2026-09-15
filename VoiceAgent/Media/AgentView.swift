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
                // 换回 SDK 的柱状图。
                //
                // 液态球的问题不是形态，是**它根本不动** —— 根因见下面那行 `.id`：
                // 这些可视化组件在 init 里就把 track 捕获进 `@StateObject`，
                // 而 `StateObject(wrappedValue:)` 的闭包**只求值一次**。
                // agent 的音轨是连上之后才出现的，第一次构造时是 nil，
                // 于是它永远绑在 nil 上，再也收不到音频。
                //
                // 上游 ControlBar 里那句 `.id(localMedia.microphoneTrack?.id)`
                // 就是在解这个 —— 音轨一到，强制换一个视图身份重新构造。
                // 我之前换成球的时候把这行丢了，所以球是死的。
                VStack(spacing: CC.Space.loose) {
                    BarAudioVisualizer(
                        audioTrack: session.agent.audioTrack,
                        barColor: CCIdentityColor.color(for: rooms.activeName),
                        barCount: 5,
                        barSpacingFactor: 0.05,
                        barMinOpacity: 0.1
                    )
                    .frame(maxWidth: 75 * .grid, maxHeight: 48 * .grid)
                    .id(session.agent.audioTrack?.id)
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
