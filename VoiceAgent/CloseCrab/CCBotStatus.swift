import Combine
import Foundation
import LiveKit

/// 两个键的名字。
///
/// ## ⚠️ 为什么不能放在 `CCBotStatus` 里
///
/// 这个工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// **所有类型默认都是 MainActor-isolated，包括裸 enum** ——
/// 所以每个 `static let` 还要**单独**标 `nonisolated`，光搬出 @MainActor 类不够。
///
/// 收消息那两个 delegate 回调是 `nonisolated` 的（`RoomDelegate` 是
/// `@objc` + `Sendable`），读不到被隔离的常量：
///
///     main actor-isolated static property 'stateAttr'
///     can not be referenced from a nonisolated context
///
/// 隔离按**声明位置**算，跟内容有没有可变状态无关。一个 `let String`
/// 读一下怎么会不安全？编译器不看这个。
///
/// 跟 `CCAvatarAttr` 同一个形状 —— 那边的注释里记着同样的坑，
/// 我这次还是又踩了一遍（2026-09-20，tommy 编译时抓到）。
enum CCBotAttr {
    nonisolated static let state = "cc.bot.state"
    nonisolated static let stepTopic = "cc.bot.step"
}

/// bot 此刻在忙什么 —— 中间那块屏的数据源。
///
/// ## 这块屏为什么归它
///
/// Chris 2026-09-20：「原本那块屏是给 live avatar 用的，但短时间内我们不会
/// 把 live avatar 打开，所以后端不 ready、那块小屏是橘色的。橘色的时候就
/// 显示整个 bot 的运行状态。」
///
/// 所以：**数字人能放就放数字人，放不了就别空着** —— 那块地方本来就是
/// 「这一刻 bot 在干什么」的位置，只是换了一种表达。
///
/// ## 两条数据，性质不同
///
/// | | 走哪 | 为什么 |
/// |---|---|---|
/// | 当下状态 | 参与者属性 `cc.bot.state` | **有持久性**：你中途打开 app 立刻看到现况 |
/// | 滚动流水 | 数据包 `cc.bot.step`（不可靠档） | 过期就没用，丢了无所谓，频率高 |
///
/// 判据是「晚一秒还需要它吗」：需要 → 属性，不需要 → 数据包。
/// 服务端那半边在 `closecrab/voice/livekit_out.py`。
///
/// ## ⚠️ 属性只在**变化时**推
///
/// `didUpdateAttributes` 给的是**变化的那几个键**，而且只在变化时才来。
/// 所以 `attach` 时必须**主动扫一遍现有参与者**把当前值读进来 ——
/// 不扫的话，进房之后到 bot 下一次动作之间那块屏是空的，
/// 而那段时间可能有几分钟。
@MainActor
final class CCBotStatus: ObservableObject {
    static let shared = CCBotStatus()

    @Published private(set) var snap: Snapshot?
    /// 最近几条流水。**只留几条** —— 它是氛围不是信息，多了就成了刷屏。
    @Published private(set) var steps: [String] = []

    private static let maxSteps = 4

    private var delegate: Delegate?
    private var attachedRooms = Set<ObjectIdentifier>()

    private init() {}

    /// 接到某个房间上。**可以重复调**（切房间、重连都会走到）。
    func attach(room: Room) {
        let key = ObjectIdentifier(room)
        if !attachedRooms.contains(key) {
            attachedRooms.insert(key)
            let fwd = Delegate(
                onState: { [weak self] raw in
                    Task { @MainActor in self?.ingest(raw) }
                },
                onStep: { [weak self] data in
                    Task { @MainActor in self?.ingestStep(data) }
                })
            delegate = fwd
            room.add(delegate: fwd)
        }
        // ⭐ 补一次当前值。见类文档那条 ⚠️。
        for p in room.remoteParticipants.values {
            if let raw = p.attributes[CCBotAttr.state] { ingest(raw) }
        }
    }

    func detach() {
        snap = nil
        steps.removeAll()
        attachedRooms.removeAll()
    }

    // MARK: - 解析

    private func ingest(_ raw: String?) {
        guard let raw, let data = raw.data(using: .utf8) else { return }
        // 解不出来就**保持上一份**，不要清空。服务端哪天多加一个字段、
        // 或者半路截断，清空会让屏幕闪一下变空 —— 那比停在旧值上更糟，
        // 因为旧值至少是真的发生过的。
        guard let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        snap = s
    }

    private func ingestStep(_ data: Data) {
        guard let s = try? JSONDecoder().decode(StepPacket.self, from: data) else { return }
        for line in s.lines where !line.isEmpty {
            steps.append(line)
        }
        if steps.count > Self.maxSteps {
            steps.removeFirst(steps.count - Self.maxSteps)
        }
    }

    // MARK: - 数据形状（跟 closecrab/core/agent_state.py 的 snapshot() 对齐）

    struct Counts: Codable, Equatable {
        var run: Int = 0
        var done: Int = 0
    }

    /// 一条子 agent 或后台命令。
    ///
    /// ⚠️ **不能叫 `Task`。** 叫 Task 会把 `_Concurrency.Task` 遮蔽掉，
    /// 于是同一个文件里 `Task { @MainActor in … }` 被解析成
    /// 「构造一个 Codable 的 CCBotStatus.Task」，报错是
    /// 「trailing closure passed to parameter of type 'any Decoder'」——
    /// **完全不提重名**，很容易被 Decoder 带偏去查 JSON 解析。
    /// 2026-09-20 就是这么栽的。
    struct Job: Codable, Equatable, Identifiable {
        var id: String = ""
        /// 真子 agent（true）还是后台命令（false）。
        ///
        /// ⚠️ **这两种必须分开显示。** 服务端上线第一分钟就被真实数据抓到：
        /// 一条后台 Bash 被当成子 agent 显示，摘要写的是那条命令的描述。
        var sub: Bool = false
        var kind: String = ""       // general-purpose 之类
        var what: String = ""       // 派它去干什么
        var act: String = ""        // 此刻在干啥
        var st: String = "running"  // running / completed / failed / unknown
        var sec: Double = 0
        var sum: String = ""        // 干完之后那一句

        enum CodingKeys: String, CodingKey { case id, sub, kind, what, act, st, sec, sum }
    }

    struct Snapshot: Codable, Equatable {
        var v: Int = 1
        /// 主 turn 在跑吗
        var on: Bool = false
        /// 在等人（等批准 / 等回答）。空串＝没在等。
        var wait: String = ""
        /// 主 agent 此刻在干啥
        var act: String = ""
        var sec: Double = 0
        var subs = Counts()
        var bg = Counts()
        var tasks: [Job] = []
        /// 挂不到任何任务上的子 agent 动作。**不为 0 就说明下面那份列表不完整。**
        var unlinked: Int = 0

        /// 这一刻该怎么概括。界面顶部那行就是它。
        var headline: String {
            if !wait.isEmpty { return wait }
            if on { return act.isEmpty ? "在忙" : act }
            return "空闲"
        }
    }

    private struct StepPacket: Codable {
        var v: Int = 1
        var sub: String = ""
        var lines: [String] = []
    }

    // MARK: - RoomDelegate 转发

    private final class Delegate: NSObject, RoomDelegate, @unchecked Sendable {
        private let onState: @Sendable (String?) -> Void
        private let onStep: @Sendable (Data) -> Void

        init(onState: @escaping @Sendable (String?) -> Void,
             onStep: @escaping @Sendable (Data) -> Void) {
            self.onState = onState
            self.onStep = onStep
            super.init()
        }

        // 参数是**变化的那几个键**，不是全量。取不到就是别的键变了，跟我们无关。
        nonisolated func room(_ room: Room, participant: Participant,
                              didUpdateAttributes attributes: [String: String]) {
            guard let raw = attributes[CCBotAttr.state] else { return }
            onState(raw)
        }

        nonisolated func room(_ room: Room, participant: RemoteParticipant?,
                              didReceiveData data: Data, forTopic topic: String,
                              encryptionType: EncryptionType) {
            guard topic == CCBotAttr.stepTopic else { return }
            onStep(data)
        }
    }
}
