import Foundation

/// 锁屏 / 灵动岛实时活动卡片上**会变的那一份**（ActivityKit 的 `ContentState`）。
/// **只依赖 Foundation，离线可测。**
///
/// 方案页 `ios-live-activity-plan-20261005`，Chris 2026-10-05 拍板的三条：
/// 卡片**跟着当前房间走**（`CCRooms.activeName`）；状态行**写 bot 在干的具体内容**
/// （`CCBotStatus.Snapshot.headline`，有子任务时带上个数）；**两种音频模式都显示卡片，
/// 暂停 / 重播按钮也一直在**（后来又简化过一次：不再按「系统播放控件」开关藏按钮）。
///
/// ## 两个 target 都编这个文件
///
/// app 往里填、扩展（`CloseCrabActivity`）照着画。共享方式见 pbxproj 里
/// "Exceptions for "VoiceAgent" folder in "CloseCrabActivity" target" 那条：
/// 文件留在 app 目录，原地多加一个 target 成员资格。所以**这里不能碰 LiveKit、
/// `CCRooms`、`CCStore`**（扩展不链 LiveKit；企业描述文件没有 App Groups，扩展也读不到
/// app 的 UserDefaults）—— 扩展能知道的**只有这份结构体里的东西**。
///
/// ## 为什么心情、皮肤、小圆点存原始字符串
///
/// 存枚举也能 Codable，但 rawValue 一旦落进系统保管的卡片里就是**跨版本的协议**：
/// 新版 app 加了一张脸、旧版扩展还在锁屏上解码时，枚举解码会整个失败（卡片变空白），
/// 字符串解码不会 —— 认不出的值在下面那几个访问器里退回一个安全默认。
///
/// ## 体积
///
/// ActivityKit 对整份内容有大小上限（官方说 4 KB）。这里最长的是 `headline`，
/// 由 `CCLiveActivityPolicy.headline` 截到 80 个字符；房间列表封顶 5 个。
nonisolated struct CCLiveActivityState: Codable, Hashable, Sendable {
    /// 其他房间的小圆点（卡片右下那一排）。
    nonisolated struct Peer: Codable, Hashable, Sendable {
        var name: String
        /// `CCPresenceDot.rawValue`
        var dot: String
    }

    /// 当前房间名（＝ bot 名）。按钮的 intent 也带着它 —— 按下去时控制的是卡片上写的
    /// 那个房间，哪怕这一秒你在 app 里已经切走了。
    var room: String
    /// `CCFaceMood.rawValue`
    var mood: String
    /// `CCFaceSkin.rawValue`。房间没选活脸时给 classic（卡片上总得有张脸，见 Policy）。
    var skin: String
    /// `CCPresenceDot.rawValue`
    var presence: String
    /// 状态行：bot 此刻在干嘛（等你的那句话 / 在调的工具 / 空闲）。
    var headline: String
    /// 正在跑的子 agent 个数（`Snapshot.subs.run`）。0 ＝ 不显示。
    var subtasks: Int
    /// 计时起点。卡片用系统的计时文本自己往前走，**不靠每秒推更新**。
    var timerStart: Date
    /// 服务端播放器在出声（`isActive && !isPaused`）。决定那颗按钮画暂停还是播放。
    var isPlaying: Bool
    /// 停住了、能继续。
    var isPaused: Bool
    /// 播完了但还能重播（`CCPlaybackRemote.canReplay`）。
    var canReplay: Bool
    var peers: [Peer]

    // MARK: 语音播放进度（2026-10-05 加，样子照 app 里的 `CCPlaybackBar`）
    //
    // ⚠️ **三个都是可选的，这条是承重的**：系统可能还保管着旧版 app 推的卡片内容，
    // 新扩展去解码时这几个键不存在 —— 非可选字段会让整份解码失败（卡片变空白），
    // 可选字段合成的是 `decodeIfPresent`，缺了就是 nil ⇒ 不画进度条。
    // 反方向（旧扩展读新 app 的）本来就没事：合成的 Codable 忽略多出来的键。
    //
    // 由 `CCLiveActivityPolicy.playMark` 算出来、在 `makeState` 里落进来；怎么画见 `playDisplay`。

    /// 在播时：这一段「从头开始播」的时刻（＝ 拿到进度那一刻 − 已播秒数）。
    /// 扩展拿它当系统计时 / 进度条的起点，**自己往前走，不靠每秒推更新**。不在播时为 nil。
    var playStart: Date?
    /// 这一段的总秒数。**nil ＝ 还在生成、长度未知**（服务端如实传 null，不编分母）。
    var playTotal: Double?
    /// 不在播（暂停 / 播完还能重播）时停在第几秒。在播时为 nil。
    var playedAtPause: Double?

    // MARK: - 扩展那边用的访问器（认不出的值退回安全默认，理由见类型注释）

    var faceMood: CCFaceMood { CCFaceMood(rawValue: mood) ?? .idle }
    var faceSkin: CCFaceSkin { CCFaceSkin.parse(skin) ?? .classic }
    var dot: CCPresenceDot { CCPresenceDot(rawValue: presence) ?? .off }

    /// 卡片过期了（15 分钟没收到更新 ⇒ app 多半已经不在了）时画的样子：
    /// 睡着的脸、灰点、「已断开」，没在播。**按钮由扩展另外藏掉**（app 不在，按了也没人接）。
    ///
    /// 为什么不照旧画最后一份：最后一份可能写着「在查东西 · 12:48」而且计时还在走 ——
    /// 一张停在半路却看着很忙的卡，比一张写着「已断开」的卡更骗人。
    var staleVersion: CCLiveActivityState {
        var s = self
        s.mood = CCFaceMood.asleep.rawValue
        s.presence = CCPresenceDot.off.rawValue
        s.headline = "已断开"
        s.subtasks = 0
        s.isPlaying = false
        s.isPaused = false
        // app 不在了，进度条按最后那份接着走就是在编（跟计时不走同一个理由）。
        s.playStart = nil
        s.playedAtPause = nil
        return s
    }

    // MARK: - 播放进度怎么画

    /// 进度那一行的四种样子。
    nonisolated enum PlayDisplay: Equatable, Sendable {
        /// 不画（没有能播 / 能重播的语音，或旧版 app 推的卡没这几个字段）。
        case hidden
        /// 在播、总长已知：左边从 `range.lowerBound` 往上数、中间进度条、右边总长 ——
        /// 三样全用系统的计时视图，**自己走到 `range.upperBound` 停住**。
        case running(ClosedRange<Date>)
        /// 在播、总长未知（还在生成）：只有已播时长在走，不画进度条，写「生成中」。
        /// **不许拿猜的分母画进度条** —— 会显示成「快播完了」，而它其实还在生成（`CCPlaybackBar` 同一条）。
        case growing(since: Date)
        /// 暂停 / 播完：静态的进度条和固定数字。`total` 为 nil 时同样不画条、写「生成中」。
        case still(played: Double, total: Double?)
    }

    var playDisplay: PlayDisplay {
        let total = playTotal.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if isPlaying, let s = playStart {
            if let t = total { return .running(s...s.addingTimeInterval(t)) }
            return .growing(since: s)
        }
        if isPaused || canReplay, let p = playedAtPause {
            return .still(played: max(0, p.isFinite ? p : 0), total: total)
        }
        return .hidden
    }

    /// 静态进度条的填充比例，夹在 0…1（服务端的 played 可能因为取整略超 total）。
    static func fraction(played: Double, total: Double) -> Double {
        guard total > 0, played.isFinite else { return 0 }
        return min(max(played / total, 0), 1)
    }

    /// 「0:12」「12:48」—— 跟 `CCPlaybackBar.clock` 同一种写法（四舍五入到秒，分钟不补零）。
    /// 超过一小时也照写分钟（「75:00」），跟 app 那边一致；单段语音用不到。
    static func clock(_ t: Double) -> String {
        let n = t.isFinite ? max(0, Int(t.rounded())) : 0
        return String(format: "%d:%02d", n / 60, n % 60)
    }

    /// 状态行完整的那句：有子任务就在后面带上个数。
    var statusLine: String {
        subtasks > 0 ? "\(headline)（\(subtasks) 个子任务）" : headline
    }
}
