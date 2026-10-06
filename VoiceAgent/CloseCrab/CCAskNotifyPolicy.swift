import Foundation

/// 「bot 在等你」的**本地通知**规则：什么时候发、什么时候撤、同一句别重复响、
/// 通知上那几颗回答按钮怎么拼、点了之后发哪句。**只依赖 Foundation，离线可测**
/// （`Tests/CCAskNotifyPolicyTests.swift`）。动手的那一层是 `CCAskNotifier`（iOS，UserNotifications）。
///
/// ## 为什么要有它（2026-10-06）
///
/// 真机诊断实锤：app 退到后台大约 20 秒之后，系统就不再收我们的 `Activity.update` 了 ——
/// 苹果只支持用 APNs 推送在后台更新实时活动，而我们的描述文件是 Google 的通配描述文件，
/// 没有 aps-environment，改不了。于是 bot 举手问问题时，锁屏卡片常常根本没显示出来。
/// Chris 拍板：**问题走本地通知**（不需要推送权限；app 靠后台音频一直活着，能自己发），
/// 卡片在后台老老实实降级（见 `CCLiveActivityPolicy.staleDate(now:foreground:)`）。
///
/// ## 几条容易写错、日常又看不出来的
///
/// - **按边沿发，不按电平发。** bot 干活时状态快照每 0.5 秒来一份，每份都会触发一次重算；
///   按「此刻在等」判的话，一句挂着的问题过了 60 秒去重窗口就会再响一次，然后每 60 秒响一次。
///   只有「在问的那句**变了**」（没问 → 问、换了一句）才考虑发。
/// - **问题出现时你正看着 app ⇒ 这一下就消费掉了**，之后切到后台也不补发 —— 你已经看到了
///   （app 里有按钮、脸也变了）。
/// - **找网络 / 重连中（脸是 `.searching`）什么都不动。** 那时的 wait 是断线前的残值，
///   既不能当「还在问」去发，也不能当「不问了」去撤 —— 网络抖一下通知就没了、
///   回来又响一遍，正是要避免的。挂断 / bot 不在（脸是睡着）才算不问了。
/// - **回答过了就撤。** 不管是在通知上点的、app 里点的还是锁屏卡片上点的 —— 三处都走
///   槽位的 `CCQuickReplySender.send`，看的是同一个 `repliedAt`。判据是「回复时刻不早于
///   这条通知发出的时刻」：上一个问题的回复不能把这一个撤掉。
/// - 判据是**脸**不是 wait 字段（跟快捷回复条 `CCQuickReply.display` 同一条）：
///   按住说话时脸是「在听」，断线时是睡着 / 找网络。
nonisolated enum CCAskNotifyPolicy {
    /// 同一房间同一句多久内不重复发。跟锁屏提醒同一个数（`CCLiveActivityPolicy.alertRepeatWindow`）、
    /// 同一个理由：重连、补发、「等你 → 在听你说 → 等你」都可能把同一句再送来一遍。
    static let repeatWindow: TimeInterval = 60
    /// 通知正文（wait 原句）最多几个字符。横幅收起时系统自己截，展开能看到更多；
    /// 这里只是防一个超长的 wait 把通知撑得没边（payload 也有大小上限）。
    static let bodyMax = 300

    /// 一句话在什么时候。
    nonisolated struct Mark: Equatable, Sendable {
        /// 去过空白的 wait 原句。
        var text: String
        var at: Date
    }

    /// 一个房间的记账。调用方按房间名各存一份，每次重算原样传回来。
    nonisolated struct Memo: Equatable, Sendable {
        /// 上一次看到「在问」的那句（nil ＝ 没在问）。**边沿检测靠它。**
        var asking: String?
        /// 通知中心里现在挂着的那条（发出的那句、什么时候发的）。nil ＝ 没挂着。
        var posted: Mark?
        /// 最近一次真正发出去的那条（60 秒去重用）。撤掉通知时**不清**：
        /// 撤掉之后同一句 60 秒内又回来，也不该再响。
        var lastPost: Mark?

        static let empty = Memo()
    }

    enum Action: Equatable, Sendable {
        /// 什么都不做。
        case none
        /// 发（同一个 identifier，会顶掉这个房间之前那条）。关联值是去过空白的 wait 原句。
        case post(String)
        /// 把这个房间的通知撤掉（已送达的和还没送达的都撤）。
        case remove
    }

    /// 一个房间重算一次。
    ///
    /// - Parameters:
    ///   - mood: 这个房间此刻的脸（`CCFaceMood.derive`，跟快捷回复条同一个判法）。
    ///   - wait: bot 状态快照的 wait 原文（没快照就传空串）。
    ///   - repliedAt: 槽位上最近一次快捷回复的时刻（`CCQuickReplySender.repliedAt`）。
    ///   - appActive: app 在前台（`UIApplication.applicationState == .active`）。
    static func step(memo: Memo, mood: CCFaceMood, wait: String, repliedAt: Date?,
                     appActive: Bool, now: Date) -> (memo: Memo, action: Action) {
        // 找网络：wait 是残值，不发也不撤，边沿也不动（回来时还是那句 ⇒ 不算变）。
        guard mood != .searching else { return (memo, .none) }
        let text = wait.trimmingCharacters(in: .whitespacesAndNewlines)
        let asking: String? = mood == .waiting && !text.isEmpty ? text : nil

        var m = memo
        var action = Action.none

        // 回答过了（回复时刻不早于通知发出时刻）⇒ 撤。
        if let p = m.posted, let r = repliedAt, r >= p.at {
            m.posted = nil
            action = .remove
        }

        guard asking != m.asking else { return (m, action) }
        m.asking = asking
        if let a = asking, !appActive, !isRepeat(a, last: m.lastPost, now: now) {
            let mark = Mark(text: a, at: now)
            m.posted = mark
            m.lastPost = mark
            return (m, .post(a))
        }
        // 不问了，或者换了一句但这次不发（前台看着 / 60 秒内发过同一句）⇒
        // 挂着的那条已经不是 bot 此刻在问的了，撤掉。
        if m.posted != nil {
            m.posted = nil
            action = .remove
        }
        return (m, action)
    }

    /// 同一句、`[last.at, last.at + 60 秒)` 里发过 ⇒ 算重复。左闭右开；时钟往回拨不算「刚发过」。
    static func isRepeat(_ text: String, last: Mark?, now: Date) -> Bool {
        guard let l = last, l.text == text else { return false }
        let dt = now.timeIntervalSince(l.at)
        return dt >= 0 && dt < repeatWindow
    }

    // MARK: - 通知长什么样

    /// 每个房间一个固定的 identifier：新问题顶掉旧问题，撤也只撤这一条。
    static func identifier(room: String) -> String { "cc.ask.\(room)" }

    static func title(room: String) -> String { "\(room) 在等你" }

    /// 正文：wait 去空白、按字符截到 `bodyMax`（超了末尾一个「…」占一位）。
    static func body(wait: String) -> String {
        let s = wait.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > bodyMax else { return s }
        return String(s.prefix(bodyMax - 1)) + "…"
    }

    /// 通知上的回答按钮：**跟 app 主界面、锁屏卡片同一个函数**（`CCQuickReply.choices`）——
    /// bot 带了推荐答案就是它的（1~4 个），没带就是固定那两句。按钮上写 `short`，点了发 `text`。
    static func choices(options: [String]?, labels: [String]?) -> [CCQuickReply.Choice] {
        CCQuickReply.choices(options: options, labels: labels)
    }

    /// 第 i 颗按钮的 action identifier。
    static func actionID(index: Int) -> String { "cc.ask.reply.\(index)" }

    /// 反过来：action identifier → 第几颗。不是我们的（系统的默认点击 / 划掉）⇒ nil。
    static func index(fromActionID id: String) -> Int? {
        let prefix = "cc.ask.reply."
        guard id.hasPrefix(prefix), let i = Int(id.dropFirst(prefix.count)), i >= 0 else { return nil }
        return i
    }

    /// 这一组按钮对应的 category identifier。
    ///
    /// category 是**注册在系统里的**（按钮的字跟着 category 走，不跟着单条通知走），
    /// 而每个问题的推荐答案都不一样 ⇒ 按「按钮上的字 ＋ 发出去的句子」算一个哈希嵌进 id：
    /// 同一组按钮同一个 id，换了一组就是另一个 id。哈希用 FNV-1a 而不是 `Hasher` ——
    /// 后者每个进程随机加盐，同一组按钮重启后会得到另一个 id（不出错，但没法测）。
    static func categoryID(choices: [CCQuickReply.Choice]) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func eat(_ bytes: some Sequence<UInt8>) {
            for b in bytes {
                h ^= UInt64(b)
                h = h &* 0x0000_0100_0000_01b3
            }
        }
        // 字段之间垫分隔符：不然 ("ab","c") 和 ("a","bc") 会撞成同一个 id。
        for c in choices {
            eat(c.short.utf8); eat([0x1f])
            eat(c.text.utf8); eat([0x1e])
        }
        return "cc.ask.cat." + String(h, radix: 16)
    }

    /// userInfo 里的键。
    static let roomKey = "cc.room"
    static let textsKey = "cc.texts"

    /// 通知带的 userInfo：房间 ＋ 每颗按钮要发的**完整原句**（按下标对应 action identifier）。
    /// 点按钮时 app 可能已经换了一个问题 —— 发的是这条通知上写的，不是此刻快照里的。
    static func userInfo(room: String, choices: [CCQuickReply.Choice]) -> [String: Any] {
        [roomKey: room, textsKey: choices.map(\.text)]
    }

    /// 点了通知上的哪颗按钮 ⇒ 给哪个房间发哪句。不是回答按钮 / userInfo 不完整 ⇒ nil。
    static func reply(userInfo: [AnyHashable: Any], actionID: String) -> (room: String, text: String)? {
        guard let i = index(fromActionID: actionID),
              let room = userInfo[roomKey] as? String, !room.isEmpty,
              let texts = userInfo[textsKey] as? [String], texts.indices.contains(i) else { return nil }
        return (room, texts[i])
    }

    /// 点的是通知本身（不是按钮）⇒ 这个房间名（app 会被系统拉到前台，顺手切到这个房间）。
    static func tappedRoom(userInfo: [AnyHashable: Any]) -> String? {
        (userInfo[roomKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
