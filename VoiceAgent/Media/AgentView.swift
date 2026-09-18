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
            // ⚠️ 走 `ccAvatarVideoTrack` 不走 `session.agent.avatarVideoTrack` ——
            //    我们的数字人挂在播报旁路名下，SDK 那条关联查不到。
            //    理由写在 `CCRooms.swift` 那个属性上。
            if let avatarVideoTrack = session.ccAvatarVideoTrack {
                SwiftUIVideoView(avatarVideoTrack)
                    .clipShape(RoundedRectangle(cornerRadius: .cornerRadiusPerPlatform))
                    .aspectRatio(avatarVideoTrack.aspectRatio, contentMode: .fit)
                    .padding(.horizontal, avatarVideoTrack.aspectRatio == 1 ? 4 * .grid : .zero)
                    .shadow(radius: 20, y: 10)
                    .mask(
                        GeometryReader { proxy in
                            let targetSize = max(proxy.size.width, proxy.size.height)
                            Circle()
                                .frame(width: videoTransition ? targetSize : 6 * .grid)
                                .position(x: 0.5 * proxy.size.width, y: 0.5 * proxy.size.height)
                                .scaleEffect(2)
                                .ccAnimation(.smooth(duration: 1.5), value: videoTransition)
                        }
                    )
                    .onAppear {
                        videoTransition = true
                    }
            } else if session.isConnected {
                // 这里原来在柱子底下写一行「在听,说吧 / 它在说 / 在想…」。
                // 2026-09-18 Chris 让去掉 —— 同样的信息现在在顶部那排
                // `CCRosterRow` 的助手牌子上（而且那儿还顺带告诉你
                // 房间里还有谁），底下再写一遍是重复。
                voiceBars
                    .transition(.opacity)
            }
        }
        .ccAnimation(.snappy, value: session.agent.audioTrack?.id)
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

}
