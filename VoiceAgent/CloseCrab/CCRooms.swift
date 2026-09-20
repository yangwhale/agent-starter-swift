import Combine
import LiveKit
import SwiftUI

/// 一个房间的全套家当：连接、本地媒体、音频选项、麦克风策略。
///
/// 之所以把这四样捆在一起，是因为它们本来就是一对一的 —— 每条连接有自己的
/// 麦克风轨、自己的处理选项。上游 starter 在 app 入口建了各一个，
/// 那是「只有一个房间」时代的写法。
@MainActor
@Observable
final class CCRoomSlot: Identifiable {
    let name: String
    let session: Session
    let localMedia: LocalMedia
    let audioOptions: AudioOptions
    let micPolicy: CCMicPolicy
    /// 这个房间里 bot 在忙什么。**一房一份，槽位建的时候绑定，此后不换。**
    /// 为什么不能是全局单例，见 `CCBotStatus` 类文档那条 ⛔。
    let botStatus: CCBotStatus

    nonisolated var id: String { name }

    /// 被我静音了 —— 连着，但它说什么我都听不见。**跨重启记住。**
    private(set) var isMuted = false

    /// 已经按当前状态处理过的远端音轨。
    ///
    /// ⚠️ 光记一个 `isMuted` 布尔是不够的，这正是 2026-09-20 那个 bug：
    /// 静音是**一次性动作**（把当时在场的轨道音量拧到 0），而远端音轨是会变的
    /// —— 参与者进出、断线重连、助手重新发布，**每来一条新轨都是 volume 1**。
    /// 于是重启（或者后台待久了自动重连）之后，小喇叭图标还在，声音却回来了：
    /// 状态记住了，动作没跟上。
    ///
    /// 记下已处理的轨道，是为了**只对新来的那几条动手** —— 读写 `volume` 会
    /// 阻塞调用线程直到 WebRTC 信令线程应用完，不能每次刷新都全量重设一遍。
    ///
    /// 用 `ObjectIdentifier` 不用 `track.sid`：sid 那个类型来自另一个包，
    /// 它的字符串表示我在 SDK 源码里核不到 —— **核不到就不用**。
    /// 对象身份在这里反而更准：一条轨道只要还是同一个对象，就已经处理过；
    /// 重连换了新对象，那本来就该重新处理。
    private var handledTracks: Set<ObjectIdentifier> = []

    private var bag = Set<AnyCancellable>()

    init(name: String) {
        self.name = name
        // 跨重启恢复。**恢复的是状态，动作由 `enforceMute()` 在轨道出现时补上** ——
        // 这里直接调 applyMute 没用，此刻一条远端轨都还没有。
        isMuted = CCStore.mutedRooms.contains(name)
        // **token source 绑死这个房间名**，不能像单房间时代那样现读全局当前房间 ——
        // 否则 N 条连接会全部跑去连同一个房间。
        session = Session(
            tokenSource: CloseCrabTokenSource(room: name),
            options: SessionOptions(
                room: Room(roomOptions: RoomOptions(
                    defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(useBroadcastExtension: true)
                )),
                preConnectAudio: false
            )
        )
        localMedia = LocalMedia(session: session)
        audioOptions = AudioOptions(localMedia: localMedia)
        micPolicy = CCMicPolicy(session: session)
        // ⭐ 现在就绑定，绑一次。**不要挪到界面 onAppear 里去** ——
        //    分页界面横滑时两页同时在场，那样会一页绑一次，后来的把先来的挤掉。
        botStatus = CCBotStatus(room: session.room)

        // 把连接的变化转发出去，方块才会自己刷新。
        // 包 `Task { @MainActor }`：sink 的闭包是 nonisolated 的，
        // 直接碰 MainActor 类的成员在 Swift 6 下编译不过。
        session.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    CCProbe.event("SlotWillChange")   // 探针：**合并前**的原始事件频率
                    self.scheduleRefresh()
                }
            }
            .store(in: &bag)
    }

    /// 这个房间里**会出声的那些远端参与者**。
    ///
    /// ## 为什么不能只看「agent」
    ///
    /// 一个房间里其实有**两个**会说话的东西，而且走的是完全不同的两条路：
    ///
    ///   语音助手   `agent-AJ_xxx`，Gemini Live 那条实时对话链路。
    ///              它有 `lk.agent.state` 属性，`session.agent` 指的就是它。
    ///   本体旁路   `<bot>-speaker`，bot 查完东西之后把结论念进房间的那条。
    ///              它**没有** agent 状态 —— 它不是一个会话，就是一路音频。
    ///
    /// 而 `session.agent` 只认前者：SDK 的 `Room.agentParticipants` 明确过滤掉
    /// 带 `lk.publish_on_behalf` 的参与者，而旁路那条正好带着这个属性
    /// （服务端当初加它是为了让网页前端别把旁路误当成助手本人）。
    ///
    /// 结果就是 Chris 09-15 看到的：跟语音助手对话时绿框和柱子都正常，
    /// 而 bunny / jarvis 查完东西在房间里播报时，**一点反应都没有** ——
    /// 因为那路声音根本不在 `session.agent.audioTrack` 上。
    ///
    /// 这里按 `kind == .agent` 取：两条路的 token 都签了 `with_kind("agent")`，
    /// 所以这一条同时抓得到它们俩，又不会把房间里的真人算进来
    /// （真人说话不该让 bot 的头像亮绿框）。
    var botParticipants: [Participant] { session.ccBotParticipants }

    /// 这个房间在不在出声。
    ///
    /// 两个来源取或：
    /// - 语音助手的**语义状态**（准，而且在它开口之前就为真）
    /// - 旁路参与者的 `isSpeaking`（服务端的活跃说话人检测，是音量驱动的）
    ///
    /// 语义状态优先是有道理的：它表达的是「轮到它了」，比音量早一点点，
    /// 界面反应会显得跟手。旁路那条没有语义状态可用，只能退回音量。
    private(set) var isSpeaking: Bool = false

    /// 给波形用的**全部** bot 音轨 —— 语音助手的 ＋ 旁路的。
    ///
    /// 返回数组不是单条：两条路可能同时有声（助手在说话时本体也播了个提示音），
    /// 而且哪条在响是运行时才知道的。表头把它们一起量，取最大值。
    private(set) var botAudioTracks: [any AudioTrack] = []

    // MARK: - 派生镜像
    //
    // ## ⛔ 为什么要镜像，而不是让界面直接读 `session`
    //
    // 这一段是 2026-09-20 耗电改造的核心。原来的写法是：
    //
    //     session.objectWillChange.sink { … self.objectWillChange.send() }
    //
    // 把 LiveKit 的**每一条**变更通知原样转发成「我变了」，而订阅槽位的是
    // 整屏布局 `CCShell` —— 于是音量抖一下、有人进房、某个属性改了，
    // 全都翻译成**整棵界面树重算**（含分页里当前看不见的那些页）。
    // 实测静止不动就 72–81% CPU、两分钟内存涨 1.7 GB。
    //
    // 现在改成：**一条订阅算出一份快照，逐项比对，只有真的变了才写。**
    // 配合 `@Observable`（属性级追踪），「谁读了哪个属性」才会被重算 ——
    // 一个只显示连接状态的方块，不会因为音量抖动而重绘。
    //
    // ## ⚠️ 界面读镜像，逻辑读 `session`
    //
    // 镜像是在**下一个 runloop** 才更新的（`objectWillChange` 是「即将改变」，
    // 在 sink 里直接读拿到的是旧值，所以必须 `Task` 跳一拍）。
    // 所以：
    //   · 界面显示 → 读镜像（晚一拍无所谓，而且这才有属性级追踪）
    //   · 判断逻辑 → 直接读 `session`（比如「连上了才发属性」那种守卫，
    //     读镜像会拿到旧值，后果是 2026-09-20 那种「守卫放行、SDK 拒收」）

    /// 连上了没有。**界面用这个**，别读 `session.isConnected`。
    private(set) var isConnected: Bool = false
    /// 这一路数字人视频轨。
    private(set) var avatarVideoTrack: (any VideoTrack)?
    /// 连接错误 / 助手错误 —— 错误条要显示它们，所以也得镜像。
    private(set) var connectionError: Error?
    private(set) var agentError: Error?

    /// 同一批事件只干一次活。
    ///
    /// ⛔ 2026-09-20 探针实测：`session.objectWillChange` **峰值 306 次/秒**，
    /// 而屏幕只有 120 Hz —— 每一帧里白跑两三轮。
    ///
    /// 上一版（8ce009c）只解决了「变了之后通知谁」，没解决「多久算一次」：
    /// 306 次回调就跑 306 次 `enforceMute()`（遍历全部远端音轨）、
    /// 306 次 `rescan()`（遍历参与者读属性）、306 次逐项比对 ——
    /// **省下的是下游重绘，省不掉上游这 306 轮遍历。**
    ///
    /// 这里做合并：第一条事件排一次活并立旗，同一批里后到的直接返回。
    /// 排的那个 Task 在当前这批 main actor 任务排干之后才跑，
    /// 所以一批事件无论多少条，只算一次。
    ///
    /// 探针分两个计数，**就是为了量出这一步的效果**：
    ///   `⚡️SlotWillChange` 合并前（LiveKit 发了多少次）
    ///   `⚡️SlotRefresh`     合并后（我们真干了多少次活）
    private var refreshScheduled = false

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            CCProbe.event("SlotRefresh")   // 探针：**合并后**真正干活的频率
            // ⭐ 每次房间有变化都补一次静音 —— 把静音从「按一下做一次」
            //    变成「一直维持住」。新参与者、重连、重新发布都从这儿过。
            self.enforceMute()
            // 状态属性只在变化时才推，bot 在我们连上之前发的那一份只能自己扫。
            if self.session.isConnected {
                self.botStatus.rescan()
            } else {
                self.botStatus.clear()
            }
            self.refresh()
        }
    }

    /// 算一份快照，逐项比对，**只有变了才写**。
    ///
    /// 这个「只有变了才写」是整件事的关键：`@Observable` 在赋值时通知，
    /// 无脑赋值等于每次都通知，属性级追踪就白做了。
    private func refresh() {
        let c = session.isConnected
        if c != isConnected { isConnected = c }

        let sp = session.ccIsSpeaking
        if sp != isSpeaking { isSpeaking = sp }

        // 轨道比 id 不比对象：重连会换新对象但内容没变，比对象会误判成「变了」。
        let tracks = session.ccBotAudioTracks
        if tracks.map(\.id) != botAudioTracks.map(\.id) { botAudioTracks = tracks }

        let av = session.ccAvatarVideoTrack
        if av?.id != avatarVideoTrack?.id { avatarVideoTrack = av }

        // Error 没法直接比，比文案 —— 错误条显示的本来也就是这个。
        let e = session.error
        if e?.localizedDescription != connectionError?.localizedDescription { connectionError = e }
        let ae = session.agent.error
        if ae?.localizedDescription != agentError?.localizedDescription { agentError = ae }
    }

    /// 旧名字留着：方块上的小波形只关心「有没有东西在响」，给它第一条就够。
    var agentAudioTrack: (any AudioTrack)? { session.agent.audioTrack ?? botAudioTracks.first }

    /// 静音 = 把这个房间所有远端音轨的音量拧到 0。
    ///
    /// 不用取消订阅：那要重新协商，切回来有一两秒空白。音量是本地的，瞬间生效。
    /// ⚠️ SDK 明说读写 `volume` 会**阻塞调用线程**直到 WebRTC 信令线程应用完，
    /// 所以丢进 detached task（`RemoteAudioTrack` 是 `@unchecked Sendable`）。
    func applyMute(_ muted: Bool) {
        isMuted = muted
        CCStore.setMuted(muted, room: name)
        handledTracks.removeAll()         // 目标变了，所有轨道都要重新处理一遍
        enforceMute()
    }

    /// 把静音**维持住**，不只是「按下那一刻做一次」。
    ///
    /// 每次房间状态变化都会调到这儿（见 `init` 里那条订阅）。只对还没按当前
    /// 目标处理过的轨道动手，所以反复调用是廉价的。
    func enforceMute() {
        let tracks = session.room.remoteParticipants.values
            .flatMap(\.audioTracks)
            .compactMap { $0.track as? RemoteAudioTrack }

        let live = Set(tracks.map(ObjectIdentifier.init))
        handledTracks.formIntersection(live)   // 走掉的轨道别一直攒着

        let pending = tracks.filter { !handledTracks.contains(ObjectIdentifier($0)) }
        guard !pending.isEmpty else { return }
        handledTracks.formUnion(pending.map(ObjectIdentifier.init))

        let volume: Double = isMuted ? 0 : 1
        Task.detached {
            for track in pending { track.volume = volume }
        }
    }
}

/// 「这个房间里谁会出声」的单一定义。
///
/// 放在 `Session` 上而不是 `CCRoomSlot` 上，是因为**分页里的每个 `AgentView`
/// 拿到的是自己那一页的 `Session`，拿不到对应的槽位**。从 `rooms.active` 取的话，
/// 每一页画的都会是当前页的数据 —— 横滑过去还没切完的那一帧就穿帮了。
///
/// 判据是 `kind == .agent`：语音助手和本体旁路的 token 都签了
/// `with_kind("agent")`，一条抓俩；房间里的真人是 `.standard`，不会被算进来。
extension Session {
    var ccBotParticipants: [Participant] {
        room.remoteParticipants.values.filter { $0.kind == .agent }
    }

    var ccBotAudioTracks: [any AudioTrack] {
        ccBotParticipants
            .flatMap(\.audioTracks)
            .compactMap { $0.track as? (any AudioTrack) }
    }

    /// 房间里那条**数字人视频轨** —— 不能只问 `session.agent`。
    ///
    /// ## 为什么 SDK 那条找不到
    ///
    /// `session.agent.avatarVideoTrack` 走的是
    /// `participant.avatarWorker?.firstCameraVideoTrack`，而 `avatarWorker`
    /// 是按 `lk.publish_on_behalf == 那个 agent 的 identity` 关联的。
    ///
    /// 我们的数字人 2026-09-18 起挂在**本体播报旁路**（`<bot>-speaker`）名下，
    /// 不是挂在语音助手名下 —— 因为对口型的音频来自播报那一路。
    /// 于是 SDK 那条关联查不到它，`avatarVideoTrack` 恒为 nil：
    /// **数字人明明在房间里、视频轨也发着（实测 384×704），屏幕上却只有柱子。**
    ///
    /// 所以这里按 `lk.avatar_provider` 全房扫 —— 跟 `CCRosterRow` 认角色
    /// 用的是同一个判据，将来再挪归属也不用改这里。
    var ccAvatarVideoTrack: (any VideoTrack)? {
        // SDK 能找到就用它的（标准接法，比如换回挂语音助手时）。
        if let t = agent.avatarVideoTrack { return t }
        for p in room.remoteParticipants.values
            where p.attributes["lk.avatar_provider"] != nil
        {
            // 优先 camera source；退而求其次拿第一条视频轨 ——
            // source 的标法各家供应商不一定一致，不该因此显示不出来。
            let pubs = p.videoTracks
            if let t = (pubs.first { $0.source == .camera } ?? pubs.first)?
                .track as? VideoTrack { return t }
        }
        return nil
    }

    /// 这一路在不在出声。语义状态优先，旁路退回服务端的活跃说话人检测。
    var ccIsSpeaking: Bool {
        if case .speaking = agent.agentState { return true }
        return ccBotParticipants.contains(where: \.isSpeaking)
    }
}

/// 多房间连接层 —— **同时连着好几个房间，话筒一次只给一个**。
///
/// ## 它解决什么
///
/// 在它之前，app 一次只能连一个房间：切房间 = 挂断当前的再拨下一个，
/// 所以要等一两秒，而且另一个房间说话你根本听不见。
/// 现在几条线同时通着，切换只是把话筒挪一下，是瞬间的。
///
/// ## 为什么不用改那 19 处读全局连接对象的界面
///
/// 关键取巧：**环境里始终只注入一个 `Session`，只不过它来自「当前选中的槽位」。**
/// 所有既有界面照常从环境里读，一行都不用动；切房间时换的是注入的那个对象，
/// SwiftUI 自己会重建订阅。真正要感知「有好几个房间」的只有顶部那排方块，
/// 它直接观察 `slots`。
///
/// ## 麦克风只有一份
///
/// 全进程只有一个音频采集设备。**任何时刻最多一个槽位开麦** —— 切换时先把旧的
/// 关掉再说。这样永远不存在两条本地音轨同时采集，绕开了那个我没法离线验证的
/// 「同一个麦克风能不能挂多条轨」的问题。
///
/// 播放那一头相反：音频引擎是进程级一份，各房间的远端轨**自动混进同一路输出**，
/// 所以「都听得见」这件事不用写一行代码。
@MainActor
@Observable
final class CCRooms {
    private(set) var slots: [CCRoomSlot] = []
    /// 话筒现在对着谁。空串 = 还没选。
    private(set) var activeName: String = ""
    /// 正在连接中的房间名，用来在界面上转圈。
    private(set) var connecting: Set<String> = []

    var active: CCRoomSlot? { slots.first { $0.name == activeName } }
    var isAnyConnected: Bool { slots.contains { $0.session.isConnected } }

    /// 槽位增删、连接状态变化时叫一声。
    ///
    /// ⚠️ **这是替掉 `CCAvatarLink` 原来那条 `rooms.objectWillChange` 订阅的。**
    /// `@Observable` 没有 `objectWillChange`，而且就算有也不该那么用 ——
    /// 那条订阅的本意是「槽位变了要重挂 delegate、重发属性」，
    /// 用「这个对象的任何属性变了」去代表它，**范围大了一个数量级**。
    /// 显式回调把「什么时候需要」写清楚了，也少一条 Combine 订阅。
    var onRoomsChanged: (() -> Void)?

    private let config = CloseCrabConfig.shared

    init() {
        activeName = config.room
        sync()
        // 勾选变了就增删槽位。用 `objectWillChange` 而不是盯具体字段：
        // 勾选、当前房间、服务端名单三者都会影响 onlineRooms，盯一个会漏。
        //
        // ⚠️ **那个 `Task` 跳跃是承重的，不是为了 actor 隔离才加的。**
        // `objectWillChange` 顾名思义是在值**改变之前**发的 —— 在 sink 里直接读
        // `config.onlineRooms` 拿到的是**旧值**，于是刚勾上的房间要等下一次
        // 无关变更才被建出来。表现是「勾了没反应，再随便点一下它才出现」。
        // 丢进 Task 推到下一个 runloop tick，那时新值已经写进去了。
        // ⚠️ 从「订阅 config.objectWillChange」换成了显式回调。
        //    原来那条要 `Task` 跳一拍才拿得到新值（objectWillChange 是
        //    「即将改变」）；`didSet` 回调触发时值已经是新的，**不用跳**。
        //    而且范围收窄了：改背景图、拨震动开关不会再来跑一遍 sync()。
        config.onSelectionChanged = { [weak self] in self?.sync() }
    }

    // MARK: - 槽位增删

    /// 让槽位和「勾了哪几个在线」对齐。多退少补，已有的原样保留 ——
    /// **不能整份重建**，那会把正连着的房间也挂掉重连。
    func sync() {
        // 增删排的决定全在 `CCRoomSelection.planSlots` 里 —— 纯函数，已离线测过。
        // 这儿只负责按计划动手：建连接、断连接、重排。
        let plan = CCRoomSelection.planSlots(
            current: slots.map(\.name),
            want: config.onlineRooms,
            active: activeName
        )
        guard !plan.toAdd.isEmpty || !plan.toRemove.isEmpty
            || plan.order != slots.map(\.name) || plan.active != activeName
        else { return }      // 没变化就别动，免得白触发一轮界面刷新

        // 先补。如果已经有房间连着，新勾的也立刻连上 —— 否则用户勾完要等下次
        // 点连接才生效，中间那段方块是灰的，看着像坏了。
        let shouldConnect = isAnyConnected
        for name in plan.toAdd {
            let slot = CCRoomSlot(name: name)
            slots.append(slot)
            if shouldConnect { connect(slot) }
        }

        // 再退。断开要等它真的断干净再丢引用，直接 removeAll 的话
        // Session 没人持有、end() 那个 Task 可能还没跑完就被回收。
        let removing = slots.filter { plan.toRemove.contains($0.name) }
        for slot in removing {
            Task { await slot.session.end() }
        }
        slots.removeAll { plan.toRemove.contains($0.name) }

        slots.sort { (plan.order.firstIndex(of: $0.name) ?? 0) < (plan.order.firstIndex(of: $1.name) ?? 0) }
        if activeName != plan.active { activeName = plan.active }
        onRoomsChanged?()
    }

    // MARK: - 连接

    /// 把所有在线房间都连上。启动页那颗按钮走这里。
    func startAll() async {
        sync()
        // 并发连，不要一个个排队 —— 六个房间串行连，最后一个要等到天荒地老。
        await withTaskGroup(of: Void.self) { group in
            for slot in slots where !slot.session.isConnected {
                group.addTask { await self.connectAwait(slot) }
            }
        }
    }

    func endAll() async {
        // 先清「连接中」：挂断发生在某个房间还在连的途中时，
        // 那个名字会永远留在集合里，方块上的转圈就再也停不下来。
        connecting.removeAll()
        for slot in slots {
            await slot.session.end()
            slot.session.restoreMessageHistory([])
        }
    }

    private func connect(_ slot: CCRoomSlot) {
        Task { await connectAwait(slot) }
    }

    private func connectAwait(_ slot: CCRoomSlot) async {
        connecting.insert(slot.name)
        await slot.session.start()
        // start() 内部连上之后会无条件开一次麦，必须在它返回之后按回去。
        // 靠监听连接状态是拦不住的，原因见 CCMicPolicy.enforceMutedAfterConnect。
        await slot.micPolicy.enforceMutedAfterConnect()
        connecting.remove(slot.name)
        onRoomsChanged?()      // 连上了 —— 该把 avatar 开关报给这个房间
    }

    // MARK: - 切换 / 静音

    /// 把话筒切给某个房间。**不重连** —— 房间本来就连着。
    ///
    /// 切之前先把旧房间的麦克风关掉：全进程只有一个采集设备，
    /// 两个槽位同时开麦是没定义的状态。
    func activate(_ name: String) {
        guard name != activeName, slots.contains(where: { $0.name == name }) else { return }
        let previous = active
        activeName = name
        config.room = name          // 让抽屉、启动页那些读 config.room 的地方跟上
        if let previous {
            Task { try? await previous.session.room.localParticipant.setMicrophone(enabled: false) }
        }
    }

    func toggleMute(_ name: String) {
        guard let slot = slots.first(where: { $0.name == name }) else { return }
        slot.applyMute(!slot.isMuted)
        // ⛔ 这里原来还有一句 objectWillChange.send()。不需要了 ——
        //    `slot.isMuted` 现在是 @Observable 属性，读它的方块会自己更新，
        //    而不读它的那些不会被打扰。
    }
}
