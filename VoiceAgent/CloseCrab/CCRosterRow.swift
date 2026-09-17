import LiveKit
import SwiftUI

/// 房间里**现在都有谁** —— 一排小牌子，谁在说话谁亮。
///
/// ## 为什么需要它
///
/// 一个房间里同时有好几个东西在出声，而且走的是完全不同的链路：
/// 语音助手、本体播报那条旁路、数字人。它们都会发声，出问题时的现象
/// 却完全不一样 —— 「没声音」可能是助手没接通、可能是旁路断了、
/// 也可能是数字人抢走了音频出口但自己没发出来。
///
/// 在这条之前，**屏幕上看不出区别**：一片安静，不知道是谁的安静。
/// 排查只能去翻服务端日志。这一排把房间成员摊开，一眼能答三个问题：
///
///   谁在这儿      助手接上没、旁路在不在、数字人来了没
///   谁在说话      绿点跟着 `isSpeaking` 走
///   数字人什么状态  `cc.avatar.state` 直接显示（on/off/hidden/unavailable）
///
/// ## 角色是按属性认的，不是按名字
///
/// identity 是服务端生成的（`agent-AJ_xxx` 这种），按前缀猜迟早猜错。
/// 判据用 LiveKit 的标准属性，跟服务端那边是同一套约定：
///
///   `lk.avatar_provider`   数字人（它同时也带 publish_on_behalf，**所以要先判它**）
///   `lk.agent.state`       语音助手（Gemini Live 那条）
///   `lk.publish_on_behalf` 本体播报旁路
///   kind == .agent         其它 agent
///   kind == .standard      真人
///
/// ⚠️ 顺序不能反：数字人和旁路**都**带 `lk.publish_on_behalf`，
/// 先判旁路的话数字人会被认成旁路，而那正是最需要看清的那一个。
///
/// ## 为什么用 TimelineView 定时刷
///
/// `isSpeaking` 是 SDK 在后台按音量算的，**它变了不一定会触发 SwiftUI 重绘** ——
/// 依赖 `objectWillChange` 的话绿点会卡住不动，看起来像「谁都没在说话」，
/// 比没有这排还误导人。这里按固定节奏自己取一次当前值，
/// 3 Hz 足够跟上说话的起停，几个牌子的重绘开销可以忽略。
struct CCRosterRow: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { _ in
            let members = roster()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(members) { m in
                        CCRosterChip(member: m)
                    }
                }
                .padding(.horizontal, 2 * .grid)
            }
            .scrollBounceBehavior(.basedOnSize)
            // 只有自己一个人时整条藏掉 —— 空房间挂一排「只有我」是噪声。
            .opacity(members.count > 1 ? 1 : 0)
        }
        .frame(height: 26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "房间成员"))
    }

    private func roster() -> [CCRosterMember] {
        var out: [CCRosterMember] = []
        let local = session.room.localParticipant
        out.append(CCRosterMember(
            id: local.identity?.stringValue ?? "me",
            role: .me,
            title: "我",
            speaking: local.isSpeaking,
            detail: nil))

        // 排序按角色，不按加入顺序 —— 顺序稳定，眼睛才不用每次重新找。
        let remotes = session.room.remoteParticipants.values
            .map(CCRosterMember.init(participant:))
            .sorted { $0.role.rank < $1.role.rank }
        out.append(contentsOf: remotes)
        return out
    }
}

// MARK: - 成员

enum CCRosterRole {
    case me, assistant, avatar, broadcast, agent, guest

    var rank: Int {
        switch self {
        case .me: 0
        case .assistant: 1
        case .avatar: 2
        case .broadcast: 3
        case .agent: 4
        case .guest: 5
        }
    }

    var symbol: String {
        switch self {
        case .me: "person.fill"
        case .assistant: "waveform.circle.fill"
        case .avatar: "person.crop.rectangle.fill"
        case .broadcast: "megaphone.fill"
        case .agent: "cpu"
        case .guest: "person"
        }
    }

    var title: String {
        switch self {
        case .me: "我"
        case .assistant: "语音助手"
        case .avatar: "数字人"
        case .broadcast: "播报"
        case .agent: "Agent"
        case .guest: "访客"
        }
    }
}

struct CCRosterMember: Identifiable {
    let id: String
    let role: CCRosterRole
    let title: String
    let speaking: Bool
    /// 牌子上的第二行小字。目前只有数字人用：显示服务端的 `cc.avatar.state`。
    let detail: String?

    init(id: String, role: CCRosterRole, title: String, speaking: Bool, detail: String?) {
        self.id = id
        self.role = role
        self.title = title
        self.speaking = speaking
        self.detail = detail
    }

    init(participant: Participant) {
        let attrs = participant.attributes
        let ident = participant.identity?.stringValue ?? "?"

        // ⚠️ 数字人必须**排在旁路前面**判：两者都带 lk.publish_on_behalf。
        let role: CCRosterRole
        if attrs["lk.avatar_provider"] != nil {
            role = .avatar
        } else if attrs["lk.agent.state"] != nil || attrs["lk.agent_name"] != nil {
            role = .assistant
        } else if attrs["lk.publish_on_behalf"] != nil {
            role = .broadcast
        } else if participant.kind == .agent {
            role = .agent
        } else {
            role = .guest
        }

        // 助手用**语义状态**判在不在说话，比音量早一点点，也不会被静音段打断。
        let speaking: Bool = if role == .assistant, let s = attrs["lk.agent.state"] {
            s == "speaking"
        } else {
            participant.isSpeaking
        }

        var detail: String?
        if role == .avatar {
            detail = attrs[CCAvatarAttr.state]
        } else if role == .assistant {
            detail = attrs["lk.agent.state"]
        }

        self.init(id: ident, role: role, title: role.title,
                  speaking: speaking, detail: detail)
    }
}

// MARK: - 单个牌子

private struct CCRosterChip: View {
    let member: CCRosterMember
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: member.role.symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(verbatim: member.title)
                .font(.system(size: 10, weight: .medium))
            if let d = member.detail, !d.isEmpty {
                Text(verbatim: d)
                    .font(.system(size: 9))
                    .foregroundStyle(.fg3)
            }
            // 说话时那个点。**不做呼吸动画** —— 一排小点各自呼吸很吵，
            // 而且这条信息只有「有/无」两态，闪不闪不增加信息。
            Circle()
                .fill(.green)
                .frame(width: 5, height: 5)
                .opacity(member.speaking ? 1 : 0)
        }
        .foregroundStyle(member.speaking ? .fg1 : .fg2)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(.fg1.opacity(member.speaking ? 0.14 : 0.07))
        )
        .ccAnimation(.default, value: member.speaking)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim:
            "\(member.title)\(member.detail.map { "，\($0)" } ?? "")\(member.speaking ? "，正在说话" : "")"))
    }
}
