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
        // **popover 而不是 sheet。**
        //
        // 同样是抄 Tide Guide 那个 session：他原本把选项放在 context menu 里，
        // 发现「进子菜单→选一个→整个菜单崩塌」要点很多下；改成 popover 之后
        // 可以连着调、不会关，收起时收回到触发它的那个控件里 ——
        // 他的原话是这给了设置**「一个来处」**。
        //
        // 换图标正是这种「调一下看一眼」的操作：从方块弹出、方块还在视野里，
        // 比一张盖住半屏、把方块本身遮掉的 sheet 合理得多。
        // `presentationCompactAdaptation(.popover)` 不能省 —— iPhone 上
        // popover 默认会退化成 sheet，不写这句改了等于没改。
        .popover(item: $iconEditing, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { ref in
            CCIconPickerSheet(room: ref.id)
                .presentationCompactAdaptation(.popover)
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
                // **两种玻璃，都带 interactive。**
                //
                // 抄的是 Tide Guide 那位开发者在 Apple 官方 session 里讲的做法
                // （"Liquid Glass showcase: Tide Guide"，Tucker MacDonald）。他明确说
                // **交互式玻璃在小按钮上收益最大** —— 那种按下去被手指整个盖住的目标，
                // 以前你得抬手才知道有没有按中；加了之后手指一落就有形变反馈。
                // 我们这个方块 54pt，正是他说的那一类。
                //
                // 非当前的用 `.identity`：**静止时完全不改变外观**，一碰才浮出高光。
                // 他把这个变体用在主潮汐波浪上 —— 不滑动时看不出是玻璃。
                // 好处是六个方块并排时不会变成六块亮片，安静，但摸上去是活的。
                if isActive {
                    RoundedRectangle(cornerRadius: CC.Radius.tile, style: .continuous)
                        .fill(.clear)
                        .frame(width: CC.Size.tile, height: CC.Size.tile)
                        .glassEffect(.regular.interactive(), in: .cc(CC.Radius.tile))
                } else {
                    RoundedRectangle(cornerRadius: CC.Radius.tile, style: .continuous)
                        .fill(identity.opacity(0.14))
                        .frame(width: CC.Size.tile, height: CC.Size.tile)
                        .glassEffect(.identity.interactive(), in: .cc(CC.Radius.tile))
                }

                face

                RoundedRectangle(cornerRadius: CC.Radius.tile, style: .continuous)
                    .strokeBorder(ringColor, style: ringStroke)
                    .frame(width: CC.Size.tile, height: CC.Size.tile)
                    .shadow(color: ring == .speaking ? identity.opacity(0.75) : .clear, radius: 14)
                    .shadow(color: ring == .speaking ? identity.opacity(0.45) : .clear, radius: 26)

                if ring == .muted {
                    // 斜杠图标，不是纯色圆点。
                    //
                    // 今年 ADA 的包容性奖（Guitar Wiz）获奖词里专门点了
                    // **Differentiate Without Color** —— 不依赖颜色也能区分。
                    // 一个红圆点的全部信息都在「红」上：色觉障碍用户看到的是
                    // 一个灰点，跟没有区别。换成喇叭加斜杠，形状自己就说清楚了，
                    // 颜色只是加强。
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(.fgSerious))
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
            // 跟中间那块同一个组件的小尺寸版本。**`.id` 不能省** ——
            // 组件在 init 里捕获 track，不给新身份就永远绑在旧的（或 nil）上，
            // 表现就是「方块里那个绿色小框框不跳了」。
            BarAudioVisualizer(audioTrack: track,
                               barColor: identity,
                               barCount: 4,
                               barSpacingFactor: 0.1,
                               barMinOpacity: 0.25)
                .frame(width: 26, height: 22)
                .id(track.id)
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
