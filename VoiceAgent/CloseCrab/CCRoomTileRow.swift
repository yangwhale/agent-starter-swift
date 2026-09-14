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
        ScrollViewReader { scroller in
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
                        .id(slot.name)
                        // 把自己的位置报给颈部。**必须挂在这一层**（方块整体）
                        // 而不是里面那个 52×52 的方框上：颈部要对准的是
                        // 「方块加名字」这个视觉单元的中线。
                        .anchorPreference(key: CCTileAnchorKey.self, value: .bounds) {
                            [slot.name: $0]
                        }
                    }
                }
                .padding(.horizontal, 4 * .grid)
                .padding(.vertical, 2 * .grid)
            }
            // 只有一两个方块时不要弹；多了才允许滚。
            .scrollBounceBehavior(.basedOnSize)
            // 横滑切到一个滚出屏幕的房间时，方块行得自己跟过去 ——
            // 否则颈部会指向一个看不见的地方，看着像断了。
            .onChange(of: rooms.activeName) { _, name in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    scroller.scrollTo(name, anchor: .center)
                }
            }
        }
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
                // 当前这个用玻璃，其余用平面底。**材质本身就是选中态** ——
                // 比再套一圈描边干净，也跟下面那块窗口是同一种材质，
                // 「它俩是一体的」这件事不用颈部一个人扛。
                if isActive {
                    RoundedRectangle(cornerRadius: CC.Radius.tile, style: .continuous)
                        .fill(.clear)
                        .frame(width: CC.Size.tile, height: CC.Size.tile)
                        .glassEffect(.regular, in: .cc(CC.Radius.tile))
                } else {
                    RoundedRectangle(cornerRadius: CC.Radius.tile, style: .continuous)
                        .fill(identity.opacity(0.14))
                        .frame(width: CC.Size.tile, height: CC.Size.tile)
                }

                face

                RoundedRectangle(cornerRadius: CC.Radius.tile, style: .continuous)
                    .strokeBorder(ringColor, style: ringStroke)
                    .frame(width: CC.Size.tile, height: CC.Size.tile)
                    .shadow(color: ring == .speaking ? identity.opacity(0.75) : .clear, radius: 14)
                    .shadow(color: ring == .speaking ? identity.opacity(0.45) : .clear, radius: 26)

                if ring == .muted {
                    Circle()
                        .fill(.fgSerious)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.bg1, lineWidth: 2))
                        .offset(x: -23, y: -23)
                }

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
                        .padding(5)
                        .background(Circle().fill(.fgAccent))
                        .offset(x: 23, y: -23)
                }
            }
            .frame(width: CC.Size.tile + 4, height: CC.Size.tile + 4)

            Text(verbatim: slot.name)
                .font(CC.Font.caption)
                .foregroundStyle(isActive ? .fg0 : .fg3)
                .lineLimit(1)
                .frame(width: CC.Size.tile + 8)

            // 选中态改成身份色的一小条。原来是整圈 3pt 描边，
            // 六个并排时整排像一串警告牌。
            Capsule()
                .fill(isActive ? identity : .clear)
                .frame(width: 18, height: 3)
        }
        .opacity(ring == .pending ? 0.45 : 1)
        .scaleEffect(ring == .speaking ? 1.05 : 1)
        .animation(CC.Motion.snap, value: ring)
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
            // 和主视图用同一套语言的小尺寸版本。原来主视图 5 根柱子、
            // 方块里 4 根，两个尺寸各说各话。
            CCLiquidOrb(track: track, state: .speaking, tint: identity)
                .frame(width: CC.Size.tile, height: CC.Size.tile)
                .scaleEffect(0.42)
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

    /// 这个 bot 的身份色。六个助理长得一样，颜色是比 11pt 的名字
    /// 快一个数量级的识别通道。
    private var identity: Color { CCIdentityColor.color(for: slot.name) }

    private var ringColor: Color {
        switch ring {
        // 描边只剩「未连接」在用 —— 说话改用发光、静音改用角标，
        // 一个方块不能同时用形状喊三件事。
        case .pending: .fg4.opacity(0.6)
        default: .clear
        }
    }

    private var ringStroke: StrokeStyle {
        switch ring {
        case .pending: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
        // 从 3pt 收到 2.5pt。3pt 在 54 见方的方块上占比太重，
        // 六个并排时整排看着像一串警告牌。
        default: StrokeStyle(lineWidth: 2.5)
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
