import LiveKitComponents

/// 中间那块主画面：**数字人在说话就播数字人，否则画柱子。**
///
/// ## 说完就收，不留停止帧
///
/// 数字人只在有音频时生成帧 —— 说完就没有新帧了。视频轨还在，画面会僵在
/// 最后一帧上不动。Chris 2026-09-18：「咱不要那个最后那个停止帧了，就正常
/// 视频，别给我拼了，有什么播什么。」
///
/// 所以显示条件不是「有没有视频轨」而是「**这一刻在不在说**」：开口展开、
/// 说完收走。收尾留了一小段宽限期，不然句子之间的换气会让画面一闪一闪。
struct AgentView: View {
    /// 这一页的槽位。**显示一律读它的镜像**（见 `CCRoomSlot` 里那段 ⛔）。
    @Environment(CCRoomSlot.self) private var slot
    @Environment(CCRooms.self) private var rooms
    /// 只为「显示网络读数」那个排障开关订阅 —— 它同时控制柱子底下那行帧数。
    private var config: CloseCrabConfig { .shared }

    /// 这一页那个房间的 bot 状态。**按 `Session` 对象身份找自己那个槽位** ——
    /// 分页里每页注入的是自己那一页的 `Session`，拿不到槽位本身（理由见
    /// `CCRooms.swift` 里 `ccBotParticipants` 那段注释），所以只能反查。
    ///
    /// ⚠️ 这里**没有** `@ObservedObject`，所以它的变化不会直接触发重算 ——
    /// 靠下面 `sampler` 那 0.2 秒一次的轮询捎带。这跟本文件里
    /// `ccIsSpeaking` 用轮询是同一个理由，不是偷懒。
    private var botStatus: CCBotStatus { slot.botStatus }

    @Environment(\.namespace) private var namespace
    /// 几何 id 按页分区。**多房间分页时不分区会跨页撞 id**，见 `geoScope` 的注释。
    @Environment(\.geoScope) private var geoScope

    /// 最后一次「在说话」的时刻。
    @State private var lastSpokeAt: Date?
    /// 当前时刻。**每个 tick 都要更新它** —— 否则说话停下来之后没有任何东西
    /// 会让 body 重算，画面就永远收不回去（`lastSpokeAt` 此时已经不再变了）。
    @State private var now = Date.now

    /// 换气宽限。两个作用：
    /// 1. 句与句之间 `isSpeaking` 会短暂落下去，照着它立刻收画面会一闪一闪。
    /// 2. **要比收起动画长一点** —— 否则刚开始收就被下一句拽回来，
    ///    画面在「收一半」和「展开」之间来回抖。
    private static let hideGrace: TimeInterval = 1.4
    /// 采样间隔。跟 `CCRosterRow` 同一个量级，别更密 —— 这两处会同时重算。
    private static let tick: TimeInterval = 0.2

    /// 定时器的起点。**必须是存下来的固定值，不能每次写 `.now`。**
    ///
    /// ⛔ 这是 2026-09-20「一从空闲变在忙就卡死、而且再也回不来」的真因：
    ///
    /// `.periodic(from:by:)` 的**第一个刻度就是 `from` 本身**。写成 `from: .now`
    /// 的话，每次重算 body 都会取一次当前时间当起点 —— 于是**每次重建都立刻
    /// 触发一跳**，那一跳又回写 `@State`，回写又触发重建。闭环，而且是死的。
    ///
    /// 为什么只在「在忙」时才发作：SwiftUI 按**读取**建依赖。空闲时那个时刻值
    /// 根本没被读到，写它不会让 body 失效，环就合不上；一变在忙就读了，
    /// 环当场闭合。`AgentView` 那个采样器是**一模一样的形状**，
    /// 只是它的条件（数字人正在说话）平时不成立，所以一直没发作。
    ///
    /// 存成 `@State` 之后起点不动了：重建之后当前刻度还是同一个值，
    /// `onChange` 不会被触发，环断开。
    @State private var epoch = Date.now

    private var avatarTrack: (any VideoTrack)? { slot.avatarVideoTrack }

    /// 现在该不该显示数字人。
    ///
    /// 条件是「**这一刻在不在说**」而不是「有没有视频轨」：数字人只在有音频时
    /// 生成帧，说完就没有新帧了，而轨还在 —— 画面会僵在最后一帧上。
    /// Chris 2026-09-18 明确说不要那张停止帧。
    /// 这块屏改显示 bot 状态。
    ///
    /// 两个条件：数字人这会儿播不了（否则数字人优先，它才是这块屏的正主），
    /// 而且**确实收到过状态**（没收到就退回柱子，别摆一块空板）。
    private var showBotStatus: Bool {
        guard !showAvatar, slot.isConnected else { return false }
        return botStatus.snap != nil
    }

    private var showAvatar: Bool {
        guard avatarTrack != nil, let t = lastSpokeAt else { return false }
        return now.timeIntervalSince(t) < Self.hideGrace
    }

    var body: some View {
        ZStack {
            // ⚠️ 走 `ccAvatarVideoTrack` 不走 `session.agent.avatarVideoTrack` ——
            //    我们的数字人挂在播报旁路名下，SDK 那条关联查不到。
            //    理由写在 `CCRooms.swift` 那个属性上。
            if let avatarVideoTrack = avatarTrack, showAvatar {
                SwiftUIVideoView(avatarVideoTrack)
                    .clipShape(RoundedRectangle(cornerRadius: .cornerRadiusPerPlatform))
                    .aspectRatio(avatarVideoTrack.aspectRatio, contentMode: .fit)
                    .padding(.horizontal, avatarVideoTrack.aspectRatio == 1 ? 4 * .grid : .zero)
                    .shadow(radius: 20, y: 10)
                    .transition(.ccLineReveal)
            } else if showBotStatus {
                // 数字人放不了的时候，这块地方显示「bot 在忙什么」。
                //
                // Chris 2026-09-20 定的：「短时间内不会把 live avatar 打开，
                // 后端不 ready，那块小屏是橘色的。橘色的时候就显示整个 bot
                // 的运行状态。」
                //
                // 判据是「有没有状态可显示」，**不是「数字人是不是 unavailable」** ——
                // 后者要等服务端回话，在它回话之前这块屏会先空一会儿；
                // 而 bot 状态是本来就在的，有就该显示。
                CCBotStatusPanel(status: botStatus)
                    .transition(.opacity)
            } else if slot.isConnected {
                // 这里原来在柱子底下写一行「在听,说吧 / 它在说 / 在想…」。
                // 2026-09-18 Chris 让去掉 —— 同样的信息现在在顶部那排
                // `CCRosterRow` 的助手牌子上（而且那儿还顺带告诉你
                // 房间里还有谁），底下再写一遍是重复。
                voiceBars
                    .transition(.opacity)
            }
        }
        // ⚠️ 时长从 `CCLineReveal.duration` 取，**别在这儿另写一个数** ——
        //    两处不一致的话进场退场节奏对不上，而那种不对劲很难指认。
        //    曲线用 linear：三段时序已经在 `CCLineReveal` 里编排好了，
        //    外面再叠一条缓动会把「先快后慢」压平，又变回看不出过程。
        .ccAnimation(.linear(duration: CCLineReveal.duration), value: showAvatar)
        .ccAnimation(.snappy, value: showBotStatus)
        // ⛔ 这儿原来有一句 `botStatus.attach(room:)`。**绑定不能放在界面里** ——
        //    分页横滑时两页同时 onAppear，后来那次会把先来那次的 delegate 挤掉。
        //    现在绑定在 `CCRoomSlot.init`，一房一次。
        .ccAnimation(.snappy, value: slot.agentAudioTrack?.id)
        // ⭐ id 必须带页分区。横滑时相邻页同时在场，不分区就是 N 个 view
        //    在同一个 group 里都当 source —— SwiftUI 对此的行为是未定义的，
        //    而 09-19 那次看门狗崩溃的栈正卡在 preference 传递上
        //    （`HostPreferencesTransform.updateValue`），matchedGeometryEffect
        //    底层走的就是 preference。
        .matchedGeometryEffect(id: "agent-\(geoScope)", in: namespace!)
        // ⚠️ **没有数字人就整个不装。** 见 `sampler` 的注释。
        .overlay { if avatarTrack != nil { sampler } }
    }

    // MARK: - 采样

    /// ⚠️ **必须轮询采样，不能用 `.onChange(of: session.ccIsSpeaking)`。**
    ///
    /// `ccIsSpeaking` 读的是 `participant.isSpeaking` / `agentState`，这些**不保证
    /// 会让 `Session` 发出变更通知** —— 不通知就不重算 body，`onChange` 也就
    /// 永远不触发。顶上那排 `CCRosterRow` 当初就是踩了这个才改成 `TimelineView`
    /// 定时刷的，这里是同一个坑，用同一个办法。
    ///
    /// 放在 `overlay` 里而不是包住整个 body：`TimelineView` 每个 tick 都会重算
    /// 它的内容，包住主画面的话 `SwiftUIVideoView` 会跟着每秒被重算五次。
    /// ⚠️ **只在有数字人视频轨时才挂**（见上面 `.overlay` 那一行）。
    ///
    /// 它存在的唯一理由是给「说完之后收画面」那段宽限期计时 ——
    /// 没有数字人就没有画面要收，这个 5 Hz 的定时器纯属白跳。
    /// 而数字人**默认是关的**，所以绝大多数时候它现在根本不存在。
    ///
    /// 2026-09-20：原来它无条件常驻。当时还兼着「采样 isSpeaking」的活，
    /// 现在 `slot.isSpeaking` 是 @Observable 镜像，那一半理由也没了。
    private var sampler: some View {
        TimelineView(.periodic(from: epoch, by: Self.tick)) { ctx in
            Color.clear
                .allowsHitTesting(false)
                .onChange(of: ctx.date, initial: true) { _, t in
                    now = t
                    if slot.isSpeaking { lastSpokeAt = t }
                    // 轨没了就立刻清掉，不用等宽限期 ——
                    // 那不是「说完了」，是「走了」。
                    if avatarTrack == nil { lastSpokeAt = nil }
                }
        }
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
            tracks: slot.botAudioTracks,
            isSpeaking: slot.isSpeaking,
            tint: CCIdentityColor.color(for: rooms.activeName),
            showsDebug: config.netReadout
        )
    }

}
