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
        return s
    }

    /// 状态行完整的那句：有子任务就在后面带上个数。
    var statusLine: String {
        subtasks > 0 ? "\(headline)（\(subtasks) 个子任务）" : headline
    }
}
