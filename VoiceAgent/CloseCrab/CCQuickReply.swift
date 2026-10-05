import Foundation

/// 「等你回话」时的快捷回复 —— **app 主界面和锁屏实时活动共用的一份规则**。
/// **只依赖 Foundation，离线可测**（`Tests/CCQuickReplyTests.swift`）。
///
/// Chris 2026-10-05：「快捷回复先在 app 主界面做好，锁屏卡片只是复用。」
/// 所以文字、什么时候出现、「已回复」显示多久都只在这里写一次 ——
/// 两处各写一份，迟早一处改了文案另一处没改，或者一处 3 秒一处 5 秒。
///
/// ## 发出去走哪
///
/// 不在这里（这里不碰 LiveKit）。两处都调槽位上的 `CCQuickReplySender.send`，
/// 它用的是 app 本来的文字通道 `session.send(text:)`（LiveKit 文本流 `lk.chat`，
/// 跟聊天框同一条），由 bot 本体接收、注入它自己的对话。
///
/// ## 两个 target 都编这个文件
///
/// 扩展（`CloseCrabActivity`）要画按钮上的字，所以它跟 `CCFaceMood` 一样在 pbxproj 的
/// "Exceptions for "VoiceAgent" folder in "CloseCrabActivity" target" 里。
nonisolated enum CCQuickReply {
    /// 一颗按钮：发给 bot 的完整原句 ＋ 地方不够时显示的简写。
    nonisolated struct Choice: Hashable, Sendable {
        /// **发给 bot 的就是这句，「已回复：…」里显示的也是这句。**
        var text: String
        /// 按钮放不下整句时才用（界面用 `ViewThatFits` 先试整句）。只是显示，不发出去。
        var short: String
        /// SF Symbol。
        var symbol: String
    }

    /// Chris 2026-10-05 定的两句。
    static let choices = [
        Choice(text: "没问题，请继续", short: "请继续", symbol: "checkmark"),
        Choice(text: "按照你的想法来", short: "按你的来", symbol: "hand.thumbsup"),
    ]

    /// 点了之后「已回复：…」显示多久。这 3 秒里按钮先收起来（防连按）。
    static let repliedShowFor: TimeInterval = 3
    /// 按钮上方那句「bot 在等你什么」最多几个字符（wait 原文去空白后截断）。
    static let promptMax = 40

    /// 界面上这一块此刻长什么样。
    nonisolated enum Display: Equatable, Sendable {
        /// 不出现。
        case hidden
        /// 刚点过：只显示「已回复：<完整原句>」。
        case replied(String)
        /// 在等你：显示 bot 等的那句（可能为空串 ⇒ 不画那一行）＋ 两颗按钮。
        case offer(prompt: String)
    }

    /// 一次算清楚该画什么。
    ///
    /// - 刚点过（`[repliedAt, repliedAt + 3 秒)`，左闭右开、时钟倒退不算）⇒ `.replied`，
    ///   **不管还在不在等** —— 点完 bot 很快就清掉 wait，这时候提示还得留够 3 秒才读得到。
    /// - 否则在「等你回话」（`CCFaceMood.waiting`）⇒ `.offer`。
    ///   ⚠️ 判据是**脸**不是 `wait` 字段：断线时 wait 是残值（脸是睡着 / 找网络），
    ///   按住说话时脸是「在听」—— 这两种都不该冒出按钮。跟脸一份规则，不各判各的。
    /// - 其余 ⇒ `.hidden`（离开等你就自动收起）。
    static func display(mood: CCFaceMood, wait: String, repliedText: String?, repliedAt: Date?,
                        now: Date) -> Display {
        if let line = repliedLine(text: repliedText, at: repliedAt, now: now) { return .replied(line) }
        guard mood == .waiting else { return .hidden }
        return .offer(prompt: prompt(wait: wait))
    }

    /// 「已回复：<完整原句>」，只在 `[at, at + 3 秒)` 里有，否则 nil。
    static func repliedLine(text: String?, at: Date?, now: Date) -> String? {
        guard let text, let at else { return nil }
        let dt = now.timeIntervalSince(at)
        guard dt >= 0, dt < repliedShowFor else { return nil }
        return "已回复：\(text)"
    }

    /// 「已回复」到点要撤下 —— 这不是属性变化，没人通知，得自己定闹钟。窗口外返回 nil。
    static func repliedRecheck(at: Date?, now: Date) -> Date? {
        guard let at, repliedLine(text: "", at: at, now: now) != nil else { return nil }
        return at.addingTimeInterval(repliedShowFor)
    }

    /// bot 在等你什么：wait 去空白、按字符截到 `promptMax`（超了末尾一个「…」占一位）。
    static func prompt(wait: String) -> String {
        let s = wait.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > promptMax else { return s }
        return String(s.prefix(promptMax - 1)) + "…"
    }
}
