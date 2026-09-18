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
    /// 正在放大看谁的形象。nil = 没在看。
    @State private var previewing: CCPersonaRole?

    private var roomName: String { session.room.name ?? "" }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { _ in
            HStack(spacing: 6) {
                ForEach(roster()) { m in
                    CCRosterChip(member: m, room: roomName, persona: persona,
                                 onTapPersona: { previewing = m.role.personaRole })
                }
            }
            .padding(.horizontal, 2 * .grid)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 44)
        .onAppear { persona.ensureAll(room: roomName) }
        .onChange(of: roomName) { _, r in persona.ensureAll(room: r) }
        .sheet(item: $previewing) { role in
            CCPersonaPreview(room: roomName, role: role, persona: persona)
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
        case .broadcast: "本人"          // 会被 bot 名字盖掉，见 CCRosterMember
        case .agent: "助手"
        case .guest: "访客"
        }
    }

    /// 这个牌子对应哪张脸 —— 有的才能长按换图。
    ///
    /// Chris 2026-09-18：「长按语音助手和长按 Bunny 都能上传一个照片。」
    /// **「数字人」那块不给** —— 它是渲染出来的结果，不是输入；
    /// 挂在它身上会让人以为改的是「当前这段视频」。
    var personaRole: CCPersonaRole? {
        switch self {
        case .assistant: .assistant
        case .broadcast: .principal
        default: nil
        }
    }
}

struct CCRosterMember: Identifiable {
    let id: String
    let role: CCRosterRole
    let title: String
    let speaking: Bool
    /// 牌子上的第二行小字。**现在只有数字人有**（开/关），而且是中文 ——
    /// 助手那行原来写 `lk.agent.state` 的英文原值，Chris 2026-09-18 让去掉：
    /// 「语音助手 listening 就太长了，光叫语音助手就完了呗。」
    /// 说没说话右边那个绿点已经讲清楚了，写一遍英文既重复又把牌子撑宽。
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

        // ⚠️ 小字**不放英文原值**。Chris 2026-09-18：「英文的部分字不要了，
        //    那『语音助手 listening』就太长了，光叫语音助手就完了呗。」
        //    助手那行直接去掉 —— 说没说话右边那个绿点已经讲清楚了，
        //    再写一遍 listening/speaking 是重复，还把牌子撑宽。
        //    数字人那行保留但翻成中文：开/关是真信息（用户自己拨的开关），
        //    而且两个字不占地方。
        var detail: String?
        if role == .avatar {
            // 状态是房间级的，由调用方扫出来传进来 —— 数字人自己不写这个键。
            detail = CCRosterMember.avatarStateText(avatarState)
        }

        // 本人那一路显示 bot 自己的名字，不写「播报」—— 那是实现细节。
        // identity 形如 `bunny-speaker`，砍掉后缀就是名字。
        var title = role.title
        if role == .broadcast {
            let base = ident.hasSuffix("-speaker")
                ? String(ident.dropLast("-speaker".count)) : ident
            if !base.isEmpty { title = base.prefix(1).uppercased() + base.dropFirst() }
        }

        self.init(id: ident, role: role, title: title,
                  speaking: speaking, detail: detail)
    }

    /// `cc.avatar.state` 翻成中文。认不出来的原样显示 —— 宁可露出一个
    /// 没见过的值，也别把它吞掉变成空白。
    static func avatarStateText(_ raw: String?) -> String? {
        switch raw {
        case nil, "": nil
        case "on": "开"
        case "off": "关"
        case "hidden": "隐藏"
        case "unavailable": "不可用"
        default: raw
        }
    }
}

extension CCPersonaRole: Identifiable {
    var id: String { rawValue }
}

// MARK: - 单个成员牌子

private struct CCRosterChip: View {
    let member: CCRosterMember
    let room: String
    @ObservedObject var persona: CCPersona
    let onTapPersona: () -> Void

    /// 这个牌子有没有自己的一张脸。没有的（我 / 数字人 / 访客）就还画图标。
    private var personaRole: CCPersonaRole? { member.role.personaRole }
    private var thumb: Image? {
        personaRole.flatMap { persona.images[$0.key(room: room)] }
    }
    private var busy: Bool {
        personaRole.map { persona.uploading.contains($0.key(room: room)) } ?? false
    }

    var body: some View {
        HStack(spacing: 5) {
            if let personaRole {
                // ⭐ 有脸的角色画缩略图，没设过就画一个「加图」的占位 ——
                //    占位本身就是在告诉用户「这儿能传图」，比任何提示文案都省地方。
                ZStack {
                    if let thumb {
                        thumb.resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 11))
                            .foregroundStyle(.fg3)
                    }
                    if busy {
                        // 上传中要挡住重复点击，也要让人看出「在传」——
                        // 没有这个反馈的话用户会反复按。
                        Color.black.opacity(0.45)
                        ProgressView().controlSize(.mini).tint(.white)
                    }
                }
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .onTapGesture(perform: onTapPersona)
            } else {
                Image(systemName: member.role.symbol)
                    .font(.system(size: 12, weight: .semibold))
            }
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
        .modifier(CCPersonaPicker(room: room, role: personaRole, persona: persona))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim:
            "\(member.title)\(member.detail.map { "，\($0)" } ?? "")\(member.speaking ? "，正在说话" : "")"))
        .accessibilityHint(Text(verbatim:
            personaRole == nil ? "" : "轻点头像放大，长按换一张"))
    }
}

// MARK: - 换图 / 放大看

/// 长按换图。单独抽成 modifier 是因为 `PhotosPicker` 只有 iOS 有，
/// 而 macOS / visionOS 那两个 target 也要能编过。
private struct CCPersonaPicker: ViewModifier {
    let room: String
    /// nil = 这个牌子没有自己的脸（我 / 数字人 / 访客），**整个手势都不挂**。
    /// 挂一个按了没反应的长按，比没有更让人困惑。
    let role: CCPersonaRole?
    @ObservedObject var persona: CCPersona
    #if os(iOS)
        @State private var pick: PhotosPickerItem?
        @State private var showing = false
    #endif

    // ⚠️ 两个分支返回的类型不一样（挂了手势的 vs 原样），必须 @ViewBuilder。
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
            if let role { picker(content, role: role) } else { content }
        #else
            content
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private func picker(_ content: Content, role: CCPersonaRole) -> some View {
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
                            persona.upload(room: room, role: role,
                                           data: data, contentType: ctype)
                        }
                    }
                    pick = nil
                }
    }
    #endif
}

// MARK: - 放大看

private struct CCPersonaPreview: View {
    let room: String
    let role: CCPersonaRole
    @ObservedObject var persona: CCPersona
    @Environment(\.dismiss) private var dismiss

    private var key: String { role.key(room: room) }
    private var who: String { role == .assistant ? "语音助手" : "本人" }

    var body: some View {
        VStack(spacing: 4 * .grid) {
            if let img = persona.images[key] {
                img.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3 * .grid))
            } else {
                VStack(spacing: 2 * .grid) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 34))
                        .foregroundStyle(.fg3)
                    Text(verbatim: "\(who)还没设形象图")
                        .font(.system(size: 14))
                        .foregroundStyle(.fg2)
                    Text(verbatim: "长按上面那块「\(who)」牌子可以传一张")
                        .font(.system(size: 12))
                        .foregroundStyle(.fg3)
                }
            }
            if let err = persona.lastError[key] {
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
