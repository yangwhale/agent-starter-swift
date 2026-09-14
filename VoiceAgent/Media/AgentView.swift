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
                // 液态球取代原来那 5 根柱子。换形态的理由写在 CCLiquidOrb 里:
                // 柱状图把「没声音」映射成「最矮」,而最矮长得像渲染失败。
                VStack(spacing: CC.Space.loose) {
                    CCLiquidOrb(
                        track: session.agent.audioTrack,
                        state: session.agent.agentState ?? .listening,
                        tint: CCIdentityColor.color(for: rooms.activeName)
                    )
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
