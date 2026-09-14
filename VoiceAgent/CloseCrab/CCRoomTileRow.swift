import LiveKitComponents
import SwiftUI

/// 顶部那一排小方块 —— **多房间唯一看得见的操作面板**。
///
/// 连了几个房间，这里就有几个方块。它不是装饰：多房间之后，
/// 没有别的地方能看出另一个房间连着没有、在不在说话，也没地方切过去。
///
/// ## 方块上显示什么
///
///   波形   那个房间的 agent 正在出声时会抖动 —— 用 SDK 现成的
///          `BarAudioVisualizer`，喂它那个房间的 agent 音轨。
///          **比「绿灯闪一闪」信息量大得多**：能看出说得急还是缓。
///   绿圈   正在说话
///   红圈   被我静音了（连着，但听不见）
///   虚线圈 还没连上 / 正在连
///   无圈   在线、能说、此刻没说
///   🎤     话筒现在对着它
///
/// ## 手势
///
///   单击   把话筒切给它（**瞬间**，不重连）
///   双击   静音 / 取消静音
///   长按   换图标
///
/// 单击和双击必须用 `ExclusiveGesture` 串起来，否则 SwiftUI 会把双击的第一下
/// 也当成单击派发，结果「切房间 + 静音」一起发生。代价是单击晚约 0.25 秒。
struct CCRoomTileRow: View {
    @EnvironmentObject private var rooms: CCRooms
    @State private var iconEditing: CCRoomRef?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(rooms.slots) { slot in
                    CCRoomTile(
                        slot: slot,
                        isActive: slot.name == rooms.activeName,
                        isConnecting: rooms.connecting.contains(slot.name),
                        onTap: { rooms.activate(slot.name) },
                        onDoubleTap: { rooms.toggleMute(slot.name) },
                        onLongPress: { iconEditing = CCRoomRef(id: slot.name) }
                    )
                }
            }
            .padding(.horizontal, 4 * .grid)
            .padding(.vertical, 2 * .grid)
        }
        // 只有一两个方块时不要弹；多了才允许滚。
        .scrollBounceBehavior(.basedOnSize)
        .sheet(item: $iconEditing) { ref in
            CCIconPickerSheet(room: ref.id)
        }
    }
}

/// 单个方块。
///
/// **拆成独立 View 而不是一个私有方法**：这样每个方块用 `@ObservedObject`
/// 各自订阅自己那个槽位，A 房间的 agent 说话只会重画 A 那一个方块。
/// 写成方法的话整排都要跟着重画，六个房间时每秒几十次全量重绘。
private struct CCRoomTile: View {
    @ObservedObject var slot: CCRoomSlot
    @ObservedObject private var icons = CCRoomIcons.shared

    let isActive: Bool
    let isConnecting: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onLongPress: () -> Void

    private var ring: CCTileRing {
        CCTileRing.derive(
            isConnected: slot.session.isConnected,
            isMuted: slot.isMuted,
            isSpeaking: slot.isSpeaking
        )
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.bg2)
                    .frame(width: 52, height: 52)

                face

                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(ringColor, style: ringStroke)
                    .frame(width: 52, height: 52)
                    // 说话时那圈发光。纯装饰，但它是「谁在说」最快的视觉线索。
                    .shadow(color: ring == .speaking ? .green.opacity(0.6) : .clear, radius: 7)

                if isConnecting {
                    ProgressView()
                        #if !os(macOS)
                            .controlSize(.small)
                        #endif
                }

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

            Text(verbatim: slot.name)
                .font(.system(size: 10, weight: isActive ? .bold : .regular))
                .foregroundStyle(isActive ? .fg1 : .fg3)
                .lineLimit(1)
                .frame(width: 58)
        }
        .opacity(ring == .pending ? 0.45 : 1)
        .scaleEffect(ring == .speaking ? 1.05 : 1)
        .animation(.spring(duration: 0.25), value: ring)
        .contentShape(Rectangle())
        .gesture(gestures)
        .accessibilityLabel(Text(verbatim: "\(slot.name)，\(ringDescription)"))
    }

    /// 方块中间：说话时是波形，其余时候是图标。
    ///
    /// 波形只在真的在说话时才换上去 —— 一直挂着的话，六个方块就是六个
    /// 常驻的动画层，白烧电，而且静止的波形看着像坏了。
    @ViewBuilder
    private var face: some View {
        if ring == .speaking, let track = slot.agentAudioTrack {
            BarAudioVisualizer(audioTrack: track,
                               agentState: .speaking,
                               barCount: 4,
                               barSpacingFactor: 0.08,
                               barMinOpacity: 0.2)
                .frame(width: 34, height: 30)
                .transition(.opacity)
        } else {
            Text(verbatim: icons.icon(for: slot.name))
                .font(.system(size: icons.hasCustomIcon(slot.name) ? 26 : 20, weight: .semibold))
                .foregroundStyle(.fg1)
                .transition(.opacity)
        }
    }

    private var gestures: some Gesture {
        let double = TapGesture(count: 2).onEnded {
            // 没连上的方块双击不该有反应 —— 静音一个没连上的房间是空动作，
            // 但红圈会亮，那就成了骗人的界面。
            guard slot.session.isConnected else { return }
            onDoubleTap()
        }
        let single = TapGesture(count: 1).onEnded {
            guard !isActive else { return }
            onTap()
        }
        let long = LongPressGesture(minimumDuration: 0.45).onEnded { _ in onLongPress() }
        // 顺序即优先级：先长按，再双击，最后单击。
        return long.exclusively(before: double.exclusively(before: single))
    }

    // MARK: - 样式

    private var ringColor: Color {
        switch ring {
        case .speaking: .green
        case .muted: .red
        case .pending: .fg3.opacity(0.5)
        case .idle: .clear
        }
    }

    private var ringStroke: StrokeStyle {
        switch ring {
        case .pending: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
        default: StrokeStyle(lineWidth: 3)
        }
    }

    private var ringDescription: String {
        switch ring {
        case .speaking: "正在说话"
        case .muted: "已静音"
        case .pending: isConnecting ? "连接中" : "未连接"
        case .idle: "在线"
        }
    }
}

/// `sheet(item:)` 的载荷。
///
/// **刻意不给 `String` 加 `Identifiable`** —— 那是给标准库类型做追溯遵循，
/// 一旦依赖里也来一份，整个工程会以「重复遵循」编译失败，
/// 而报错位置会指到一个跟这儿八竿子打不着的文件。包一层就没这个风险。
struct CCRoomRef: Identifiable, Equatable {
    let id: String
}
