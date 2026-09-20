import LiveKitComponents
import SwiftUI

/// 顶部那一排小方块 —— **多房间唯一看得见的操作面板**。
///
/// 连了几个房间，这里就有几个方块。它不是装饰：多房间之后，
/// 没有别的地方能看出另一个房间连着没有、在不在说话，也没地方切过去。
///
/// ## 方块上显示什么
///
///   波形   那个房间**有东西在出声**时会抖动 —— 用 `CCVoiceBars`，
///          喂它那个房间全部 bot 音轨（语音助手的 ＋ 本体播报那条旁路的）。
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
/// 三个都带触觉反馈（见 `CCHaptics`）。这三下经常是在地铁上、走路时做的，
/// 眼睛不一定在屏幕上 —— 手上有没有回应决定了要不要低头确认一次。
///
/// 单击和双击必须用 `ExclusiveGesture` 串起来，否则 SwiftUI 会把双击的第一下
/// 也当成单击派发，结果「切房间 + 静音」一起发生。代价是单击晚约 0.25 秒。
struct CCRoomTileRow: View {
    @Environment(CCRooms.self) private var rooms
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                // 减弱动态效果时直接跳过去 —— 这是一整排内容横向滑动，
                // 正是那个开关要挡的东西。跳过去信息不丢：目标方块照样居中。
                withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) {
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
    let slot: CCRoomSlot
    private var icons: CCRoomIcons { .shared }
    /// 只为「手写体」那个开关订阅。**不订阅的话开关拨了字不会变** ——
    /// `CCType` 是纯函数，它不知道谁该重绘。
    private var config: CloseCrabConfig { .shared }

    /// 方块边长，跟随动态字号。
    ///
    /// **这是整个方块唯一的缩放源** —— 字号、角标位置、角标字号全部按它派生
    /// （见下面那几个计算属性）。理由见 `CCType` 里那段：字和承载它的几何
    /// 必须一起长，否则大字号下名字会被固定宽度截掉。
    ///
    /// 基准取 `.caption` 而不是 `.body`：方块底下那行名字是全 app 最小的字，
    /// 按最小的那一档缩放，整排在辅助功能字号下才不至于失控。
    /// 方块行本身在横向 `ScrollView` 里，长出屏幕可以滚，所以不设上限 ——
    /// **完整支持动态字号，而不是卡一个天花板了事。**
    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = CC.Size.tile

    /// 下面几个都是「占方块边长的几分之几」，写成比例而不是写死点数，
    /// 这样 `side` 一变它们自动跟上，不会出现字长了角标还钉在原地的情况。
    private var nameSize: CGFloat { side * 11 / CC.Size.tile }
    private var initialSize: CGFloat { side * 20 / CC.Size.tile }
    private var emojiSize: CGFloat { side * 26 / CC.Size.tile }
    private var badgeSize: CGFloat { side * 9 / CC.Size.tile }
    private var badgeInset: CGFloat { side * 23 / CC.Size.tile }

    let isActive: Bool
    let isConnecting: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onLongPress: () -> Void

    /// 写成计算属性而不是在调用处用三目。
    ///
    /// `isActive ? [.isButton, .isSelected] : .isButton` 两边一个是数组字面量
    /// 一个是单值，要靠 `OptionSet` 的字面量推断去统一 —— 在 Xcode 里多半能过，
    /// 但这是**离线检查不出来、只有真机编译才知道**的那类写法。写开就不用赌。
    ///
    /// ⚠️ 用 `formUnion` 不用 `insert`：`OptionSet.insert` 返回
    /// `(inserted:memberAfterInsert:)` 且**不是** `@discardableResult`，
    /// 丢掉返回值会报 `result of call to 'insert' is unused`。
    /// 这里本来也不关心「之前在不在」，`formUnion` 才是这个意图。
    private var tileTraits: AccessibilityTraits {
        var traits: AccessibilityTraits = .isButton
        if isActive { traits.formUnion(.isSelected) }
        return traits
    }

    private var ring: CCTileRing {
        CCTileRing.derive(
            isConnected: slot.isConnected,
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
                        .frame(width: side, height: side)
                        .glassEffect(.regular.interactive(), in: .cc(CC.Radius.tile))
                } else {
                    RoundedRectangle(cornerRadius: CC.Radius.tile, style: .continuous)
                        .fill(identity.opacity(0.14))
                        .frame(width: side, height: side)
                        .glassEffect(.identity.interactive(), in: .cc(CC.Radius.tile))
                }

                face

                RoundedRectangle(cornerRadius: CC.Radius.tile, style: .continuous)
                    .strokeBorder(ringColor, style: ringStroke)
                    .frame(width: side, height: side)
                    .shadow(color: ring == .speaking ? .ccSpeaking.opacity(0.9) : .clear, radius: 10)
                    .shadow(color: ring == .speaking ? .ccSpeaking.opacity(0.5) : .clear, radius: 22)

                if ring == .muted {
                    // 斜杠图标，不是纯色圆点。
                    //
                    // 今年 ADA 的包容性奖（Guitar Wiz）获奖词里专门点了
                    // **Differentiate Without Color** —— 不依赖颜色也能区分。
                    // 一个红圆点的全部信息都在「红」上：色觉障碍用户看到的是
                    // 一个灰点，跟没有区别。换成喇叭加斜杠，形状自己就说清楚了，
                    // 颜色只是加强。
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: badgeSize, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(.fgSerious))
                        .overlay(Circle().strokeBorder(.bg1, lineWidth: 2))
                        .offset(x: -badgeInset, y: -badgeInset)
                }

                if isConnecting {
                    ProgressView()
                        #if !os(macOS)
                            .controlSize(.small)
                        #endif
                }

                if isActive {
                    Image(systemName: "mic.fill")
                        .font(.system(size: badgeSize, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(.fgAccent))
                        .offset(x: badgeInset, y: -badgeInset)
                }
            }
            .frame(width: side + 4, height: side + 4)

            Text(verbatim: slot.name)
                .font(CCType.roomName(nameSize, hand: config.handwritten))
                .foregroundStyle(isActive ? .fg0 : .fg3)
                .lineLimit(1)
                // 名字长短不可控（`xiaoaitongxue` 十三个字母），而这一格
                // 是按方块宽度定死的。没有这一条，长名字在任何字号下
                // 都会被截成「xiaoait…」—— 六个方块里有两个看不出是谁。
                //
                // 0.7 是下限不是常态：短名字一点都不会缩。
                .minimumScaleFactor(0.7)
                .frame(width: side + 8)

            // 选中态改成身份色的一小条。原来是整圈 3pt 描边，
            // 六个并排时整排像一串警告牌。
            Capsule()
                .fill(isActive ? identity : .clear)
                .frame(width: 18, height: 3)
        }
        .opacity(ring == .pending ? 0.45 : 1)
        .scaleEffect(ring == .speaking ? 1.05 : 1)
        .ccAnimation(CC.Motion.snap, value: ring)
        .contentShape(Rectangle())
        .gesture(gestures)
        // ## 为什么要显式合成一个元素
        //
        // 这个方块在视觉上是**一个按钮**，但在无障碍树里它是一堆东西：
        // 底板、描边、角标、波形、名字、选中条。不合成的话 VoiceOver
        // 要划六下才走完一个房间，而且念出来的是一串没有主语的碎片。
        //
        // `children: .ignore` 把里面全部忽略掉，只留我们自己写的那句话 ——
        // 也顺带让下面 `accessibilityLabel` 真的落在一个元素上。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(slot.name)，\(ringDescription)"))
        .accessibilityAddTraits(tileTraits)
        // ⚠️ **双击和长按对 VoiceOver 用户等于不存在** —— 那两个手势被
        // VoiceOver 自己接管了，传不到我们的 `gestures` 上。
        // 不补这两条命名动作，静音和换图标这两个功能对他们就是缺失的，
        // 而界面上看不出任何异样。
        .accessibilityAction(named: Text(verbatim: slot.isMuted ? "取消静音" : "静音")) {
            onDoubleTap()
        }
        .accessibilityAction(named: Text(verbatim: "更换图标")) {
            onLongPress()
        }
    }

    /// 方块中间：说话时是波形，其余时候是图标。
    ///
    /// 波形只在真的在说话时才换上去 —— 一直挂着的话，六个方块就是六个
    /// 常驻的动画层，白烧电，而且静止的波形看着像坏了。
    @ViewBuilder
    private var face: some View {
        if ring == .speaking, !slot.botAudioTracks.isEmpty {
            // 跟中间那块**同一个组件**的小尺寸版本。
            //
            // 原来用的是 SDK 的 `BarAudioVisualizer` —— 换掉的原因见
            // `CCVoiceBars` 的文档：那个组件的柱子高度只认它自己内部那份
            // 频段数据，收不到音频时在任何状态下都只是一排等高的圆点。
            //
            // 而且这里必须喂**全部** bot 音轨，不能只喂 `agentAudioTrack`：
            // bot 本体播报结论走的是另一条轨，只喂前者的话，
            // 「bunny 查完东西在房间里说话」时这个小波形完全不动。
            CCVoiceBars(tracks: slot.botAudioTracks,
                        isSpeaking: true,
                        tint: identity,
                        barWidth: 4,
                        spacing: 3,
                        maxHeight: 24,
                        glow: 0.22)
                .transition(.opacity)
        } else {
            // 传过图就画图，否则画 emoji / 首字母。
            // ⚠️ 图要**填满整个方块**（scaledToFill + clip），不留白边 ——
            //    52pt 的地方本来就小，再让内容缩在中间就更看不清了。
            if let custom = icons.image(for: slot.name) {
                custom
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Text(verbatim: icons.icon(for: slot.name))
                    // emoji 不走手写体 —— 手写字库里没有 emoji，套上去只会被系统
                    // 逐字回退，白绕一圈。只有「没设过图标、显示首字母」那种情况
                    // 才是手写体真正的用武之地：一个手写的 J 自带笔锋和不对称，
                    // 六个并排时一眼能分开，SF 的 J 不行。
                    .font(
                        icons.hasCustomIcon(slot.name)
                            ? .system(size: emojiSize, weight: .semibold)
                            : CCType.roomInitial(initialSize, hand: config.handwritten)
                    )
                    .foregroundStyle(.fg1)
                    .transition(.opacity)
            }
        }
    }

    private var gestures: some Gesture {
        let double = TapGesture(count: 2).onEnded {
            // 没连上的方块双击不该有反应 —— 静音一个没连上的房间是空动作，
            // 但红圈会亮，那就成了骗人的界面。
            //
            // 但**不能完全没反应**：方块本来就是灰的、点了也不亮，手上再没动静的话
            // 用户只会以为自己没点准，于是原地再点两下。给一记「拒绝」的震动。
            guard slot.session.isConnected else {
                CCHaptics.refuse()
                return
            }
            CCHaptics.toggleMute()
            onDoubleTap()
        }
        let single = TapGesture(count: 1).onEnded {
            // 点已经选中的那个不算拒绝，是「你已经在这儿了」—— 不给震动，
            // 免得每次误触都咯噔一下。
            guard !isActive else { return }
            CCHaptics.switchRoom()
            onTap()
        }
        let long = LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            CCHaptics.reveal()
            onLongPress()
        }
        // 顺序即优先级：先长按，再双击，最后单击。
        return long.exclusively(before: double.exclusively(before: single))
    }

    // MARK: - 样式

    /// 这个 bot 的身份色。六个助理长得一样，颜色是比 11pt 的名字
    /// 快一个数量级的识别通道。
    private var identity: Color { CCIdentityColor.color(for: slot.name) }

    private var ringColor: Color {
        switch ring {
        // 「正在说话」＝ 绿色描边 ＋ 同色外发光。
        //
        // 之前这里试过「只发光、不描边」，理由是「描边是框住，发光是发出」。
        // 那个说法在纯色背景上成立，但背景换成实景照片之后发光糊进图里就没了 ——
        // 而这是全屏最需要一眼看到的状态。实心描边在任何背景上都跳得出来。
        //
        // 颜色用绿：这是所有会议软件（Meet / Zoom / Teams / Discord）
        // 表示「此人正在说话」的共同约定，不该在这儿自创一套。
        case .speaking: .ccSpeaking
        case .pending: .fg4.opacity(0.6)
        default: .clear
        }
    }

    private var ringStroke: StrokeStyle {
        switch ring {
        case .speaking: StrokeStyle(lineWidth: 3)
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
