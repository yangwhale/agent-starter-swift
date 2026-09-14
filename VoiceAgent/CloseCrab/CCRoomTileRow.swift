import LiveKit
import SwiftUI

/// 顶部那一排小方块 —— **多房间唯一看得见的操作面板**。
///
/// 勾了哪几个房间在线，这里就有几个方块。它不是装饰：连了两个房间之后，
/// 你没法从别处知道另一个连着没有、它是不是在说话，也没地方切过去。
///
/// ## 圈的含义（判定逻辑在 `CCTileRing`，已离线测过）
///
///   绿圈   它正在出声
///   红圈   被我静音了 —— 连着，但它说什么我都听不见
///   虚线圈 还没连上（多房间连接层落地前，非当前房间都是这个）
///   无圈   在线、能说、此刻没说
///   🎤     话筒现在对着它
///
/// ## 手势
///
///   单击   把话筒切给它
///   双击   静音 / 取消静音
///   长按   换图标
///
/// **单击和双击必须用 `ExclusiveGesture` 串起来。** SwiftUI 默认会把双击的
/// 第一下也当成单击派发，于是双击的结果是「切房间 + 静音」一起发生。
/// 代价是单击晚约 0.25 秒才落地 —— 可接受，那段时间里没有任何网络动作。
struct CCRoomTileRow: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var config = CloseCrabConfig.shared
    @ObservedObject private var icons = CCRoomIcons.shared

    /// 被我静音的房间。多房间连接层落地前，只有当前房间这一项真的生效。
    @State private var muted: Set<String> = []
    @State private var iconEditing: CCRoomRef?
    @State private var switching = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(config.onlineRooms, id: \.self) { name in
                    tile(name)
                }
            }
            .padding(.horizontal, 4 * .grid)
            .padding(.vertical, 2 * .grid)
        }
        // 只有一两个方块时居中；多了才从左边排开。
        // 固定左对齐的话，两个方块会孤零零缩在角上，很难看。
        .scrollBounceBehavior(.basedOnSize)
        .sheet(item: $iconEditing) { ref in
            CCIconPickerSheet(room: ref.id)
        }
    }

    // MARK: - 一个方块

    private func tile(_ name: String) -> some View {
        // 「连上了」目前等价于「它是当前房间且会话连着」。多房间落地后
        // 这一行会换成查对应房间的连接状态，**方块本身一个字都不用改**。
        let isActive = name == config.room
        let isConnected = isActive && session.isConnected
        let ring = CCTileRing.derive(
            isConnected: isConnected,
            isMuted: muted.contains(name),
            isSpeaking: isConnected && isAgentSpeaking
        )

        return VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.bg2)
                    .frame(width: 52, height: 52)

                Text(verbatim: icons.icon(for: name))
                    .font(.system(size: icons.hasCustomIcon(name) ? 26 : 20, weight: .semibold))
                    .foregroundStyle(.fg1)

                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(ringColor(ring), style: ringStroke(ring))
                    .frame(width: 52, height: 52)
                    // 说话时那圈发光。纯装饰，但它是「谁在说」最快的视觉线索 ——
                    // 比让人去读名字快得多。
                    .shadow(color: ring == .speaking ? .green.opacity(0.6) : .clear, radius: 7)

                if isActive {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(.blue))
                        .offset(x: 22, y: -22)
                }
            }
            .frame(width: 56, height: 56)

            Text(verbatim: name)
                .font(.system(size: 10, weight: isActive ? .bold : .regular))
                .foregroundStyle(isActive ? .fg1 : .fg3)
                .lineLimit(1)
                .frame(width: 58)
        }
        .opacity(ring == .pending ? 0.45 : 1)
        .scaleEffect(ring == .speaking ? 1.05 : 1)
        .animation(.spring(duration: 0.25), value: ring)
        .contentShape(Rectangle())
        .gesture(gestures(name: name, isActive: isActive, isConnected: isConnected))
        .disabled(switching)
        .accessibilityLabel(Text(verbatim: "\(name)，\(ringDescription(ring))"))
    }

    // MARK: - 手势

    private func gestures(name: String, isActive: Bool, isConnected: Bool) -> some Gesture {
        let double = TapGesture(count: 2).onEnded {
            // 没连上的方块双击不该有反应 —— 静音一个还没连上的房间是空动作，
            // 但红圈会亮，那就成了骗人的界面。
            guard isConnected else { return }
            toggleMute(name)
        }
        let single = TapGesture(count: 1).onEnded {
            guard !isActive else { return }
            switchTo(name)
        }
        let long = LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            iconEditing = CCRoomRef(id: name)
        }
        // 顺序即优先级：先看是不是长按，再看双击，最后才是单击。
        return long.exclusively(before: double.exclusively(before: single))
    }

    // MARK: - 动作

    /// 静音 = 把那个房间里所有远端音轨的音量拧到 0。
    ///
    /// 用音量而不是取消订阅：取消订阅会让服务端停止下发，重新订阅要重新协商，
    /// 切回来时有一两秒空白。音量是本地的，瞬间生效、瞬间恢复。
    ///
    /// ⚠️ SDK 文档明说读写 `volume` 会**阻塞调用线程**直到 WebRTC 信令线程应用完，
    /// 所以放进 `Task.detached` 里做，别卡住主线程上的动画。
    private func toggleMute(_ name: String) {
        let willMute = !muted.contains(name)
        if willMute { muted.insert(name) } else { muted.remove(name) }

        let tracks = session.room.remoteParticipants.values
            .flatMap(\.audioTracks)
            .compactMap { $0.track as? RemoteAudioTrack }
        Task.detached {
            for track in tracks { track.volume = willMute ? 0 : 1 }
        }
    }

    /// 切房间。现在仍然是挂断再连（`end()` → `start()`），跟抽屉里那条路一样 ——
    /// 多房间连接层落地后，这里会变成纯本地切换，不再重连。
    private func switchTo(_ name: String) {
        guard !switching else { return }
        config.room = name
        guard session.isConnected else { return }
        switching = true
        Task {
            await session.end()
            await session.start()
            switching = false
        }
    }

    // MARK: - 样式

    /// 当前房间的 agent 在不在说话。
    ///
    /// 用 `agent.agentState` 而不是自己算音量：那是 agent 的**语义状态**
    /// （listening / thinking / speaking），服务端下发、跨端一致。
    /// 自己做 VAD 的话，它"嗯"一声也会亮绿圈，而正在 thinking 的沉默又什么都不显示。
    ///
    /// 用 `if case` 不用 `==`，免得依赖 `AgentState` 是不是 Equatable。
    private var isAgentSpeaking: Bool {
        if case .speaking = session.agent.agentState { return true }
        return false
    }

    private func ringColor(_ ring: CCTileRing) -> Color {
        switch ring {
        case .speaking: .green
        case .muted: .red
        case .pending: .fg3.opacity(0.5)
        case .idle: .clear
        }
    }

    private func ringStroke(_ ring: CCTileRing) -> StrokeStyle {
        switch ring {
        case .pending: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
        default: StrokeStyle(lineWidth: 3)
        }
    }

    private func ringDescription(_ ring: CCTileRing) -> String {
        switch ring {
        case .speaking: "正在说话"
        case .muted: "已静音"
        case .pending: "未连接"
        case .idle: "在线"
        }
    }
}

/// `sheet(item:)` 的载荷。
///
/// **刻意不给 `String` 加 `Identifiable`** —— 那是给标准库类型做追溯遵循，
/// 一旦 SDK 或别的依赖也加了一份，整个工程会以「重复遵循」编译失败，
/// 而报错位置会指到一个跟这儿八竿子打不着的文件。包一层就没这个风险。
struct CCRoomRef: Identifiable, Equatable {
    let id: String
}
