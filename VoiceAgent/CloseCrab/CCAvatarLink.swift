import Combine
import LiveKit
import SwiftUI

/// 数字人开关的客户端这一半：**报两件事实，收一个结论**。
///
///     报出去   cc.avatar.want      用户那个开关
///     报出去   cc.client.visible   现在看得见吗（`CCVisibilityPolicy` 去过抖）
///     收回来   cc.avatar.state     服务端合成的结论
///
/// 客户端**不做最终决定** —— 服务端还要看网关通不通、8 路槽位还剩几路。
/// 判定本身在服务端 `avatar_policy.py`，那边穷举测过。
///
/// ## 为什么可见性值得单独报
///
/// app 在后台时 iOS 根本显示不了实时视频（PiP 锁屏即停，CallKit 显示不了
/// 远端画面，Live Activity 是快照）。这时候还让网关渲染，是拿 8 路里的
/// 一路去画一张没人看的脸。
///
/// ## 这里刻意不做的两件事
///
/// - **不缓存服务端状态跨连接。** 重连之后房间对象是新的，旧状态一律作废。
/// - **不自己重试。** 写失败就等下一次变化。属性不适合高频写
///   （LiveKit 文档明说超过每几秒一次会有服务端同步开销），
///   为一次失败去轮询是反着来的。
@MainActor
final class CCAvatarLink: ObservableObject {
    /// **单例，跟 `CloseCrabConfig.shared` / `CCRoomDirectory.shared` 一个理由：**
    /// 这东西本来就只该有一个 —— 两个实例会各挂一份 delegate、各写一次属性，
    /// 而属性不适合高频写。
    ///
    /// 走单例还顺手躲掉一个坑：设置页是 sheet，用 `@EnvironmentObject` 拿的话，
    /// 忘了注入不会编译报错，**是运行时崩溃**，而 `#Preview` 那个调用点必然
    /// 注入不了。
    static let shared = CCAvatarLink()

    /// 服务端最近一次回报。**是全房共享的那一份**，不是「我的」——
    /// 要判断该不该给用户看，走 `CCAvatarServerState` 上那两个方法。
    @Published private(set) var serverState: CCAvatarServerState = .unknown

    /// 上报失败的原因，给设置页显示。`nil` = 没出过错。
    @Published private(set) var lastPublishError: String?

    private let config = CloseCrabConfig.shared
    /// 由 `VoiceAgentApp` 在启动时 `attach` 进来。没接上之前所有上报都是空转 ——
    /// 不是错误，只是还没到时候。
    private weak var rooms: CCRooms?

    private var policy = CCVisibilityPolicy()
    /// 宽限到期的闹钟。每次 scenePhase 变化都重排 —— 旧的必须取消，
    /// 否则「进后台→回前台→再进后台」会留下一串闹钟，
    /// 最早那个到点就把人判成看不见，而他明明在看。
    private var graceTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private var delegate: CCAvatarDelegate?

    /// **每个房间**上一次收到的值，key 是房间名。相同就不重发 ——
    /// 见上面那条高频写的限制。
    ///
    /// ⚠️ **必须按房间记，不能只记「上次发了什么」。** 只记内容的话：
    /// 拨开开关 → 发给当时连着的房间 → 记下 → 又连上一个新房间 →
    /// 内容没变于是跳过 → **新房间永远收不到**，服务端按缺省当它「没要」。
    /// 断开的房间要从这里删掉，重连后才会重新发一次。
    private var sentTo: [String: [String: String]] = [:]

    private init() {
        let forwarder = CCAvatarDelegate { [weak self] raw in
            // ⚠️ delegate 回调**不保证在主线程**（SDK 文档原话）。
            //    这一跳不能省，`serverState` 是 @Published、要在主线程改。
            Task { @MainActor in
                self?.serverState = CCAvatarServerState.parse(raw)
            }
        }
        delegate = forwarder

        // 开关一拨就重报。盯 objectWillChange 而不是具体字段，跟 CCRooms 同一个理由；
        // 同样要跳一个 runloop tick，因为它是**值改变之前**发的。
        config.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.publish() } }
            .store(in: &bag)

    }

    /// 接上房间层。**只该调一次**（`VoiceAgentApp.init`）。
    func attach(rooms: CCRooms) {
        self.rooms = rooms
        // 房间增删也要重报：新连上的房间不知道我们的开关状态。
        rooms.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.attachAndPublish() } }
            .store(in: &bag)
        attachAndPublish()
    }

    // MARK: - 前后台

    /// 单调时钟。**不能用 `Date()`** —— 墙上时钟会被 NTP 往回拨，
    /// 拨过之后 `now - since` 变成负数，宽限期就永远到不了，
    /// 人切走了却一直被当成在看。`systemUptime` 只会往前走。
    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// 把 scenePhase 喂进来。由 `CCRootView` 的 `.onChange(of: scenePhase)` 调。
    func note(phase: ScenePhase) {
        let kind: CCScenePhaseKind
        switch phase {
        case .active: kind = .active
        case .inactive: kind = .inactive
        case .background: kind = .background
        // ScenePhase 是 @frozen 之外的枚举，将来可能多一档。
        // 当成「非前台」处理：宁可多等一个宽限期，也不要把正在看的人判掉。
        @unknown default: kind = .inactive
        }

        let now = Self.now()
        if policy.update(phase: kind, now: now) { publish() }

        graceTask?.cancel()
        guard let wait = policy.deadline(from: now) else { return }
        graceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.policy.tick(now: Self.now()) {
                self.publish()
            }
        }
    }

    // MARK: - 发布

    private func attachAndPublish() {
        if let delegate, let rooms {
            for slot in rooms.slots {
                // MulticastDelegate 内部按对象去重（弱引用集合），
                // 重复 add 同一个实例不会收到两遍。
                slot.session.room.add(delegate: delegate)
            }
        }
        publish()
    }

    private func publish() {
        let attrs = [
            CCAvatarAttr.want: config.liveAvatar ? "true" : "false",
            CCAvatarAttr.visible: policy.isVisible ? "true" : "false",
        ]
        guard let rooms else { return }

        // 断开的房间先忘掉，它重连之后要重新收一次。
        // 顺带把已经不存在的槽位清掉，不然这个字典会一直长。
        let live = Set(rooms.slots.filter(\.session.isConnected).map(\.name))
        sentTo = sentTo.filter { live.contains($0.key) }

        for slot in rooms.slots where slot.session.isConnected {
            guard sentTo[slot.name] != attrs else { continue }
            // 先把要用的东西取出来再进 Task —— 闭包里别再碰 `slot`，
            // 那是个 @MainActor 类，在异步上下文里访问它的属性要额外 await。
            let room = slot.session.room
            let name = slot.name
            Task {
                do {
                    // 每次把**两个键一起**写。属性是按键合并的，
                    // 所以这不会碰掉 LiveKit 自己的 lk.* 键。
                    try await room.localParticipant.set(attributes: attrs)
                    // ⚠️ **写成功之后才记账。** 先记的话，一次失败就会被当成
                    //    「已经发过了」，下次内容没变直接跳过 —— 那个房间从此
                    //    再也收不到，而且没有任何报错。
                    self.sentTo[name] = attrs
                    self.lastPublishError = nil
                } catch {
                    // 不重试：这个房间没记账，下一次重算会自动再试一遍。
                    //
                    // ⚠️ **但必须留一个用户看得见的地方。** 最要紧的那种失败
                    //    （token 少了 `canUpdateOwnMetadata`）是**持续性**的，
                    //    重试救不了；而且两边都不报错 —— 服务端只是永远读不到属性，
                    //    现象就是「开关拨了没反应」。只 print 的话没人会去翻。
                    //
                    // `Task {}` 继承外层的 MainActor 隔离，所以这里直接赋值就行。
                    print("[CCAvatarLink] 上报失败（房间 \(name)）: \(error)")
                    self.lastPublishError = error.localizedDescription
                }
            }
        }
    }
}

/// 收 `cc.avatar.state` 的转发器。
///
/// 单独一个 `NSObject` 子类，是因为 `RoomDelegate` 是 `@objc` 协议、且要求
/// `Sendable`，而 `CCAvatarLink` 是 `@MainActor` 的 —— 两者不能是同一个类型。
/// 这里只做一件事：把值原样丢给一个 `@Sendable` 闭包，由它自己跳回主线程。
private final class CCAvatarDelegate: NSObject, RoomDelegate, @unchecked Sendable {
    private let onState: @Sendable (String?) -> Void

    init(onState: @escaping @Sendable (String?) -> Void) {
        self.onState = onState
        super.init()
    }

    // 参数是**变化的那些键**，不是全量。所以这里取不到就直接返回 ——
    // 别的键变了跟我们无关。
    nonisolated func room(_ room: Room,
                          participant: Participant,
                          didUpdateAttributes attributes: [String: String]) {
        guard let raw = attributes[CCAvatarAttr.state] else { return }
        onState(raw)
    }
}
