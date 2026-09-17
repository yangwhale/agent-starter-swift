import LiveKit
#if os(iOS)
    import PhotosUI
#endif
import SwiftUI

/// 房间里**现在都有谁**，外加**数字人用的是哪张脸**。
///
/// ## 为什么需要它
///
/// 一个房间里同时有好几个东西在出声，走的是完全不同的链路：语音助手、
/// 本体播报旁路、数字人。它们出问题的现象却一样 ——「没声音」。
/// 在这条之前屏幕上看不出区别，一片安静不知道是谁的安静，排查只能翻服务端日志。
///
///   谁在这儿      助手接上没、旁路在不在、数字人来了没
///   谁在说话      绿点跟着 `isSpeaking` 走
///   数字人状态    `cc.avatar.state` 直接显示
///   **用哪张脸**  最后那块牌子：点开放大，长按换一张
///
/// ## 「形象」那块牌子为什么单独一个，不挂在数字人身上
///
/// 数字人只在开着的时候才在房间里，而**换脸这件事在它不在的时候更常做** ——
/// 先把脸准备好再拨开开关。挂在数字人身上就变成「要先开一路 GPU 才能换图」。
///
/// ## 角色是按属性认的，不是按名字
///
/// identity 是服务端生成的（`agent-AJ_xxx` 这种），按前缀猜迟早猜错。
/// 判据用 LiveKit 的标准属性：
///
///   `lk.avatar_provider`   数字人（它同时也带 publish_on_behalf，**所以要先判它**）
///   `lk.agent.state`       语音助手
///   `lk.publish_on_behalf` 本体播报旁路
///   kind == .agent         其它 agent
///   kind == .standard      真人
///
/// ⚠️ 顺序不能反：数字人和旁路**都**带 `lk.publish_on_behalf`，
/// 先判旁路的话数字人会被认成旁路，而那正是最需要看清的那一个。
///
/// ## 为什么用 TimelineView 定时刷
///
/// `isSpeaking` 是 SDK 在后台按音量算的，**它变了不一定触发 SwiftUI 重绘** ——
/// 依赖 `objectWillChange` 的话绿点会卡住不动，看起来像「谁都没在说话」，
/// 比没有这排还误导人。
struct CCRosterRow: View {
    @EnvironmentObject private var session: Session
    @StateObject private var persona = CCPersona.shared
    @State private var previewing = false

    private var roomName: String { session.room.name ?? "" }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { _ in
            HStack(spacing: 6) {
                ForEach(roster()) { m in
                    CCRosterChip(member: m)
                }
                CCPersonaChip(room: roomName, persona: persona,
                              onTap: { previewing = true })
            }
            .padding(.horizontal, 2 * .grid)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 44)
        .onAppear { persona.ensure(room: roomName) }
        .onChange(of: roomName) { _, r in persona.ensure(room: r) }
        .sheet(isPresented: $previewing) {
            CCPersonaPreview(room: roomName, persona: persona)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "房间成员"))
    }

    /// `cc.avatar.state` 是**房间级**的一条信息，但它挂在写它的那个参与者身上。
    ///
    /// ⚠️ 写它的是谁**会变**：曾经是语音助手，2026-09-18 起是 bot 的播报旁路。
    /// 所以不要去某个固定角色身上找 —— 那次改归属之后，「数字人」牌子上的
    /// 状态就一直是空的（我去数字人自己身上找了，而它从来不写这个键）。
    /// 全房间扫一遍，谁写了就用谁的。
    private func avatarState() -> String? {
        for p in session.room.remoteParticipants.values {
            if let v = p.attributes[CCAvatarAttr.state], !v.isEmpty { return v }
        }
        return session.room.localParticipant.attributes[CCAvatarAttr.state]
    }

    private func roster() -> [CCRosterMember] {
        var out: [CCRosterMember] = []
        let local = session.room.localParticipant
        out.append(CCRosterMember(
            id: local.identity?.stringValue ?? "me",
            role: .me, title: "我", speaking: local.isSpeaking, detail: nil))
        // 排序按角色，不按加入顺序 —— 顺序稳定，眼睛才不用每次重新找。
        let state = avatarState()
        out.append(contentsOf: session.room.remoteParticipants.values
            .map { CCRosterMember(participant: $0, avatarState: state) }
            .sorted { $0.role.rank < $1.role.rank })
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
    /// 牌子上的第二行小字：数字人显示 `cc.avatar.state`，助手显示它的状态。
    let detail: String?

    init(id: String, role: CCRosterRole, title: String, speaking: Bool, detail: String?) {
        self.id = id
        self.role = role
        self.title = title
        self.speaking = speaking
        self.detail = detail
    }

    init(participant: Participant, avatarState: String? = nil) {
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
            // 状态是房间级的，由调用方扫出来传进来 —— 数字人自己不写这个键。
            detail = avatarState
        } else if role == .assistant {
            detail = attrs["lk.agent.state"]
        }

        self.init(id: ident, role: role, title: role.title,
                  speaking: speaking, detail: detail)
    }
}

// MARK: - 单个成员牌子

private struct CCRosterChip: View {
    let member: CCRosterMember

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: member.role.symbol)
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: member.title)
                    .font(.system(size: 12, weight: .medium))
                if let d = member.detail, !d.isEmpty {
                    Text(verbatim: d)
                        .font(.system(size: 9))
                        .foregroundStyle(.fg3)
                }
            }
            // 说话时那个点。**不做呼吸动画** —— 一排小点各自呼吸很吵，
            // 而这条信息只有「有/无」两态，闪不闪不增加信息。
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
                .opacity(member.speaking ? 1 : 0)
        }
        .foregroundStyle(member.speaking ? .fg1 : .fg2)
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(Capsule().fill(.fg1.opacity(member.speaking ? 0.16 : 0.08)))
        .ccAnimation(.default, value: member.speaking)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim:
            "\(member.title)\(member.detail.map { "，\($0)" } ?? "")\(member.speaking ? "，正在说话" : "")"))
    }
}

// MARK: - 形象牌子（点开放大 / 长按换图）

private struct CCPersonaChip: View {
    let room: String
    @ObservedObject var persona: CCPersona
    let onTap: () -> Void

    private var thumb: Image? { persona.images[room] }
    private var busy: Bool { persona.uploading.contains(room) }

    var body: some View {
        content
            .frame(height: 34)
            .background(Capsule().fill(.fg1.opacity(0.08)))
            .contentShape(Capsule())
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: thumb == nil ? "还没设形象图" : "当前形象图"))
            .accessibilityHint(Text(verbatim: "轻点放大，长按换一张"))
            .modifier(CCPersonaPicker(room: room, persona: persona))
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 6) {
            ZStack {
                if let thumb {
                    thumb.resizable().scaledToFill()
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 12))
                        .foregroundStyle(.fg3)
                }
                if busy {
                    // 上传中要挡住重复点击，也要让人看出「在传」——
                    // 没有这个反馈的话用户会反复按。
                    Color.black.opacity(0.45)
                    ProgressView().controlSize(.mini).tint(.white)
                }
            }
            .frame(width: 44, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            Text(verbatim: "形象")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.fg2)
        }
        .padding(.horizontal, 8)
    }
}

/// 长按换图。单独抽成 modifier 是因为 `PhotosPicker` 只有 iOS 有，
/// 而 macOS / visionOS 那两个 target 也要能编过。
private struct CCPersonaPicker: ViewModifier {
    let room: String
    @ObservedObject var persona: CCPersona
    #if os(iOS)
        @State private var pick: PhotosPickerItem?
        @State private var showing = false
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .onLongPressGesture(minimumDuration: 0.4) {
                    CCHaptics.reveal()
                    showing = true
                }
                .photosPicker(isPresented: $showing, selection: $pick,
                              matching: .images, photoLibrary: .shared())
                .onChange(of: pick) { _, item in
                    guard let item else { return }
                    Task {
                        // 拿原始字节，**不要先转成 UIImage 再编码** ——
                        // 那会多一次有损重编码，而参考图的清晰度直接决定
                        // 生成出来那张脸的清晰度。
                        guard let data = try? await item.loadTransferable(type: Data.self),
                              let ctype = CCPersona.sniff(data)
                        else { return }
                        await MainActor.run {
                            persona.upload(room: room, data: data, contentType: ctype)
                        }
                    }
                    pick = nil
                }
        #else
            content
        #endif
    }
}

// MARK: - 放大看

private struct CCPersonaPreview: View {
    let room: String
    @ObservedObject var persona: CCPersona
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 4 * .grid) {
            if let img = persona.images[room] {
                img.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3 * .grid))
            } else {
                VStack(spacing: 2 * .grid) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 34))
                        .foregroundStyle(.fg3)
                    Text(verbatim: "这个房间还没设形象图")
                        .font(.system(size: 14))
                        .foregroundStyle(.fg2)
                    Text(verbatim: "长按上面那块「形象」牌子可以传一张")
                        .font(.system(size: 12))
                        .foregroundStyle(.fg3)
                }
            }
            if let err = persona.lastError[room] {
                // 失败原因要显示出来 ——「点了没反应」是这类功能最常见的投诉，
                // 而后端把原因写得很清楚（签名过期、图太大、不是图片…）。
                Text(verbatim: err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button("完成") { dismiss() }
                .font(.system(size: 15, weight: .medium))
        }
        .padding(5 * .grid)
        .presentationDetents([.medium])
    }
}
