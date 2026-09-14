import Combine
import LiveKit
import SwiftUI

/// 一个房间的全套家当：连接、本地媒体、音频选项、麦克风策略。
///
/// 之所以把这四样捆在一起，是因为它们本来就是一对一的 —— 每条连接有自己的
/// 麦克风轨、自己的处理选项。上游 starter 在 app 入口建了各一个，
/// 那是「只有一个房间」时代的写法。
@MainActor
final class CCRoomSlot: ObservableObject, Identifiable {
    let name: String
    let session: Session
    let localMedia: LocalMedia
    let audioOptions: AudioOptions
    let micPolicy: CCMicPolicy

    nonisolated var id: String { name }

    /// 被我静音了 —— 连着，但它说什么我都听不见。
    @Published var isMuted = false

    private var bag = Set<AnyCancellable>()

    init(name: String) {
        self.name = name
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

        // 把连接的变化转发出去，方块才会自己刷新。
        // 包 `Task { @MainActor }`：sink 的闭包是 nonisolated 的，
        // 直接碰 MainActor 类的成员在 Swift 6 下编译不过。
        session.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } }
            .store(in: &bag)
    }

    /// 这个房间的 agent 在不在说话。用语义状态，不是音量 VAD。
    var isSpeaking: Bool {
        if case .speaking = session.agent.agentState { return true }
        return false
    }

    /// 给方块上的波形用。没连上或 agent 没上线时是 nil，波形会自己画成平的。
    var agentAudioTrack: (any AudioTrack)? { session.agent.audioTrack }

    /// 静音 = 把这个房间所有远端音轨的音量拧到 0。
    ///
    /// 不用取消订阅：那要重新协商，切回来有一两秒空白。音量是本地的，瞬间生效。
    /// ⚠️ SDK 明说读写 `volume` 会**阻塞调用线程**直到 WebRTC 信令线程应用完，
    /// 所以丢进 detached task（`RemoteAudioTrack` 是 `@unchecked Sendable`）。
    func applyMute(_ muted: Bool) {
        isMuted = muted
        let tracks = session.room.remoteParticipants.values
            .flatMap(\.audioTracks)
            .compactMap { $0.track as? RemoteAudioTrack }
        Task.detached {
            for track in tracks { track.volume = muted ? 0 : 1 }
        }
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
final class CCRooms: ObservableObject {
    @Published private(set) var slots: [CCRoomSlot] = []
    /// 话筒现在对着谁。空串 = 还没选。
    @Published private(set) var activeName: String = ""
    /// 正在连接中的房间名，用来在界面上转圈。
    @Published private(set) var connecting: Set<String> = []

    var active: CCRoomSlot? { slots.first { $0.name == activeName } }
    var isAnyConnected: Bool { slots.contains { $0.session.isConnected } }

    private let config = CloseCrabConfig.shared
    private var bag = Set<AnyCancellable>()

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
        config.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.sync() } }
            .store(in: &bag)
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
        objectWillChange.send()
    }
}
