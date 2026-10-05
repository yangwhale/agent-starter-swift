import Foundation

/// bot「活脸」此刻该摆哪张脸。**只依赖 Foundation，离线可测。**
///
/// Chris 2026-10-05 批的方案（`ios-bot-face-plan-20261005`）：
/// 纯黑底、两只白眼睛，靠**眼皮形状和动作**表达 bot 在干嘛。
/// 这个文件只回答「哪张脸」；脸怎么动在 `CCFaceMotion`，怎么画在 `CCFaceView`。
///
/// ## 八张脸，按优先级取第一个命中的
///
/// | 脸 | 信号 |
/// |---|---|
/// | 睡着 `asleep` | 小圆点灰：没连 / 已挂断 |
/// | 迷糊找人 `searching` | 小圆点黄、红：正在连 / 断线重试 |
/// | 等你回话 `waiting` | bot 状态 `wait` 不为空（等你批准或回答） |
/// | 在听你说 `listening` | 你按住说话 |
/// | 在说话 `speaking` | 这个房间在出声（**且你没把它静音**） |
/// | 在查东西 `working` | bot 状态 `on == true` |
/// | 刚干完 `done` | `on` 真→假且带了一句总结，**之后 3 秒内** |
/// | 空闲 `idle` | 其余 |
///
/// 两条排序理由：
/// - **没连上时其它都不看。** 断线时 `wait` / `on` 是上一次连着时的残值，
///   拿它画「在查东西」等于把过期的消息当成现况。
/// - **「等你」排在「在说话」前面** —— 那是唯一需要你动手的状态，
///   bot 一边念一边等你批准时，念的内容你可以晚点听，批准不能漏。
///
/// ## 静音时为什么不画「在说话」
///
/// 静音＝这个房间的声音被我关了（音量 0 ＋ 让服务端停发）。服务端的活跃
/// 说话人检测仍然会报「在说」，照着画的话就是一张**笑着张嘴却没声音**的脸 ——
/// 那看起来像是 app 坏了（「默认状态不该长得像错误状态」）。
/// 静音时它落到下一档（在查东西 / 空闲），跟你实际感受到的一致。
nonisolated public enum CCFaceMood: String, Sendable, Equatable, CaseIterable {
    case asleep, searching, waiting, listening, speaking, working, done, idle

    /// 「刚干完」那张笑脸挂多久。**这是唯一的旋钮**，测试只钉区间不钉值。
    public static let doneWindow: TimeInterval = 3

    /// - Parameters:
    ///   - presence: 在线小圆点（`CCRooms.presence(for:)`）。
    ///   - wait: bot 状态里的 `wait`；没收到过状态传空串。
    ///   - on: bot 状态里的 `on`；没收到过状态传 false。
    ///   - holding: 你正按住说话。
    ///   - speaking: 这个房间在出声（`CCRoomSlot.isSpeaking`）。
    ///   - muted: 这个房间被你静音了。
    ///   - finishedAt: 最近一次「刚干完」事件的时刻（见 `CCFaceEvent`）。
    ///   - now: **由调用方传入** —— 不读系统时钟，测试才能把边界钉死。
    public static func derive(
        presence: CCPresenceDot,
        wait: String,
        on: Bool,
        holding: Bool,
        speaking: Bool,
        muted: Bool,
        finishedAt: Date?,
        now: Date
    ) -> CCFaceMood {
        switch presence {
        case .off: return .asleep
        case .connecting, .retrying: return .searching
        // 橙点（连着但 bot 不在 / 网差）**照常往下判**：它还是连着的，
        // bot 状态也是新鲜的。网差这件事小圆点已经在说了，脸不用再说一遍。
        case .degraded, .online: break
        }
        if !wait.isEmpty { return .waiting }
        if holding { return .listening }
        if speaking && !muted { return .speaking }
        if on { return .working }
        if let f = finishedAt, isWithinDoneWindow(finishedAt: f, now: now) { return .done }
        return .idle
    }

    /// `[finishedAt, finishedAt + 3s)` —— 左闭右开。
    ///
    /// `now` 早于 `finishedAt`（系统时间被往回调过）**不算**：
    /// 那种情况下笑脸会一直挂到时间追上来为止，可能是几分钟。
    public static func isWithinDoneWindow(finishedAt: Date, now: Date) -> Bool {
        let dt = now.timeIntervalSince(finishedAt)
        return dt >= 0 && dt < doneWindow
    }

    /// 在查东西时底下亮几个打字点。**有子任务就多亮几个**，封顶 5 ——
    /// 再多就成了进度条，而它只是个「很忙」的氛围信号。
    public static func typingDots(runningSubtasks: Int) -> Int {
        min(5, 3 + max(0, runningSubtasks))
    }

    /// 读屏念的那句（脸本身是纯图形，不能只靠形状传信息）。
    public var spoken: String {
        switch self {
        case .asleep: "睡着了"
        case .searching: "正在找网络"
        case .waiting: "在等你回话"
        case .listening: "在听你说"
        case .speaking: "在说话"
        case .working: "在查东西"
        case .done: "刚干完"
        case .idle: "空闲"
        }
    }
}

/// 会让 app「叮」一声的两个瞬间。**只认边沿，不认电平** ——
/// `wait` 一直挂着不会一直叮，只在它从空变成非空那一下叮。
nonisolated public enum CCFaceEvent: String, Sendable, Equatable {
    /// 开始等你回话：两声上扬。
    case waiting
    /// 刚干完（带着一句总结收尾）：一声。
    case finished

    /// 两份相邻的 bot 状态之间发生了什么。
    ///
    /// `prev == nil`（刚连上、或断线清空之后的第一份）**一律不算事件** ——
    /// 否则每次重连都会对着一份早就存在的「等你批准」叮一声，
    /// 而那件事你在断线前已经听过了。
    ///
    /// 两件事同时发生（干完的同时开始等你）时报「等你」：那是需要你动手的。
    public static func detect(
        prevOn: Bool?, prevWait: String?,
        nextOn: Bool, nextWait: String, nextSum: String
    ) -> CCFaceEvent? {
        guard let prevOn, let prevWait else { return nil }
        if prevWait.isEmpty && !nextWait.isEmpty { return .waiting }
        if prevOn && !nextOn && !nextSum.isEmpty { return .finished }
        return nil
    }
}

/// 同一件事 3 秒内只叮一次。
///
/// 为什么要有：服务端的状态是属性推送，重连、补发、两条路径（delegate
/// 和 rescan）都可能把同一个边沿送来两遍。叮声是打断性的，重复一次就很吵。
///
/// 键由调用方给（房间名＋事件），**不同事件、不同房间互不挡**。
nonisolated public struct CCChimeGate: Sendable {
    public static let window: TimeInterval = 3
    private var last: [String: TimeInterval] = [:]

    public init() {}

    /// 返回这一次该不该响；该响就顺手记下时刻。
    ///
    /// 时间倒退（`t` 比上次还早）按「该响」处理并重新记 ——
    /// 卡在一个未来时刻上的话，接下来那段时间就永远叮不出来了。
    public mutating func admit(_ key: String, at t: TimeInterval) -> Bool {
        if let prev = last[key], t >= prev, t - prev < Self.window { return false }
        last[key] = t
        return true
    }
}
