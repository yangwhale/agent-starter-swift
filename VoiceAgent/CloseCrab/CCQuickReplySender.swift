import Foundation
import LiveKit
import Observation

/// 快捷回复的**出口**：把一句完整原句经 app 的文字通道发给 bot，并记下「刚回复过」。
///
/// 规则（文字、什么时候出现、「已回复」多久）在纯 Foundation 的 `CCQuickReply`；
/// 这里只做两件事：发、记。主界面的 `CCQuickReplyBar` 和锁屏实时活动
/// （`CCLiveActivity.quickReply`）都调同一个 `send` —— 所以在锁屏上点了，
/// 回到 app 也显示「已回复」，反过来一样。
///
/// ## 走哪条路
///
/// `session.send(text:)` —— 跟聊天框（`ChatInputView`）同一条：LiveKit 文本流 `lk.chat`。
/// 2026-10-05 起 `lk.chat` 由 bot 本体（`<房间名>-speaker`）接收、注入它自己的对话，
/// 语音助手不再接。SDK 顺手把这句记进聊天记录（loopback），跟手打的一样。
///
/// ⚠️ 文本流是单向的：返回成功只说明**发出去了**，不说明 bot 收下了。
@MainActor
@Observable
final class CCQuickReplySender {
    /// 刚发出的那句完整原句（「已回复：…」显示它）。
    private(set) var repliedText: String?
    /// 什么时候点的。`CCQuickReply.display` 拿它判 3 秒窗口。
    private(set) var repliedAt: Date?
    /// 最近一次没发出去的原因；成功时清空。界面要显示 —— 静默失败只会让人觉得「这按钮不灵」。
    private(set) var lastError: String?

    @ObservationIgnored private let session: Session

    init(session: Session) {
        self.session = session
    }

    /// 发一句。**先记「已回复」再 await**：按下去按钮要立刻收起（Chris 要的），
    /// 不能等网络往返；没发出去再撤回并记下原因。
    @discardableResult
    func send(_ text: String) async -> Bool {
        let at = Date()
        repliedText = text
        repliedAt = at
        lastError = nil
        guard await session.send(text: text) != nil else {
            // 只撤回自己这一次（这期间又点了一次的话，别把后一次的记录抹掉）。
            if repliedAt == at {
                repliedText = nil
                repliedAt = nil
            }
            lastError = session.error.map { "没发出去：\($0.localizedDescription)" } ?? "没发出去"
            return false
        }
        return true
    }
}
