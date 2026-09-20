import LiveKit
#if os(iOS)
    import PhotosUI
#endif
import SwiftUI

/// 房间里**现在都有谁**，外加**各自用的是哪张脸**。
///
/// ## 为什么要这么一排牌子
///
/// 一个房间里同时挂着好几个会出声的东西：语音助手、本体播报旁路、Avatar。
/// 它们出问题的现象却一样 ——「没声音」。有这排牌子，「谁在这儿、谁在说话」
/// 一眼就能看见，不用去翻日志。
///
/// ## 状态靠**在不在**表达，不靠写字
///
/// Chris 2026-09-18：「那个开就没必要 —— 你要没开，Avatar 不会出现在这个
/// 窗口里。只要它出现，就说明开了。」
///
/// 这条比省地方值钱：**存在本身就是状态**。再写一个 `on` 是把同一件事说两遍，
/// 而两遍还可能不一致（属性更新和参与者进出不是一个时序）—— 那时候人该信哪个？
/// 同理，助手那行原来写的 `listening / speaking` 也去掉了：右边那个绿点
/// 已经说清楚了。
///
/// ## 牌子上的三个手势
///
///     单击   看这个角色的形象图（放大）
///     双击   开 / 关这个角色的 Avatar —— 开着的名字后面有个小屏幕标记
///     长按   换一张形象图
///
/// Chris 2026-09-18：「那个 Avatar 的开关，你把它给我从系统配置里边拿出来，
/// 放到每一个这个房间里。双击 bunny 可以打开 Avatar，然后在 Bunny 头上放一个
/// 标记的图标……双击语音助手的时候，这个 Avatar 就会变成语音助手开，
/// 顺便把那个巴尼就拿走。」
///
/// 开关长在它作用的对象上，不用离开正在看的画面去设置页里改一个只对眼前这个
/// 房间有意义的东西。互斥（开一个关另一个）是**客户端的产品选择**，
/// 协议本身允许两个都开 —— 见 `CCAvatarRoles.swift`。
///
/// ## 角色怎么认（顺序不能反）
///
///   `lk.avatar_provider`   Avatar（它同时也带 publish_on_behalf，**所以要先判它**）
///   `lk.agent.state`       语音助手
///   `lk.publish_on_behalf` 本体播报旁路（显示 bot 自己的名字）
///   `kind == .agent`       其它 agent
///
/// ⚠️ Avatar 和旁路**都**带 `lk.publish_on_behalf`，先判旁路的话 Avatar 会被
/// 认成旁路，而那正是最需要看清的那一个。
///
/// ## 为什么用 TimelineView 定时刷
///
/// `participant.isSpeaking` / `agentState` **不保证会让 `Session` 发出变更
/// 通知** —— 不通知就不重算 body，牌子会停在旧状态上。所以定时采样。

struct CCRosterRow: View {
    /// ⚠️ **故意不用 `@EnvironmentObject`。** 这排牌子本来就靠下面那个
    /// 0.35 秒的 `TimelineView` 定时重算（因为 `isSpeaking` 不保证发通知），
    /// 所以它**不需要订阅** —— 订阅只会让它额外被 Session 的每一条变化叫醒，
    /// 实测那是 306 次/秒。读槽位上的 `session` 拿数据，刷新交给定时器。
    @Environment(CCRoomSlot.self) private var slot
    private var persona: CCPersona { .shared }
    /// Avatar 开关住在这儿（每房间、每角色），顺带拿服务端回报来给标记上色。
    private var link: CCAvatarLink { .shared }
    /// 正在放大看谁的形象。nil = 没在看。
    @State private var previewing: CCPersonaRole?

    private var roomName: String { slot.session.room.name ?? "" }

    /// 这排牌子有多高。
    ///
    /// ⚠️ **它是挂在 `AppView` 上的 `.overlay(alignment: .top)`，overlay 不占位置** ——
    /// 它直接浮在主画面上面。以前不出事是因为主画面那两种内容（数字人视频、
    /// 声音柱子）都垂直居中，够不着顶。**任何顶对齐的内容都会被它盖住**，
    /// 所以那种内容要自己让开这么高。2026-09-20 状态屏就是这么撞上的。
    static let height: CGFloat = 44

    var body: some View {
        // 这里的 `from: .now` **是安全的**，不要照着另外两处一起改。
        // 闭包参数是 `_`（不看刻度值），而且里面**不回写任何 `@State`** ——
        // 那个自激环要「定时器回写状态、状态又被 body 读到」两头都成立才闭合。
        // 对照 `CCBotStatusPanel.epoch` 那段：那两处两头都成立，所以会死循环。
        TimelineView(.periodic(from: .now, by: 0.35)) { _ in
            HStack(spacing: 6) {
                ForEach(roster()) { m in
                    CCRosterChip(member: m, room: roomName, persona: persona, link: link,
                                 onTapPersona: { previewing = m.role.personaRole })
                }
            }
            .padding(.horizontal, 2 * .grid)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.height)
        .onAppear { persona.ensureAll(room: roomName) }
        .onChange(of: roomName) { _, r in persona.ensureAll(room: r) }
        .sheet(item: $previewing) { role in
            CCPersonaPreview(room: roomName, role: role, persona: persona)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "房间成员"))
    }

    private func roster() -> [CCRosterMember] {
        var out: [CCRosterMember] = []
        let local = slot.session.room.localParticipant
        out.append(CCRosterMember(
            id: local.identity?.stringValue ?? "me",
            role: .me, title: "我", speaking: local.isSpeaking))
        // 排序按角色，不按加入顺序 —— 顺序稳定，眼睛才不用每次重新找。
        out.append(contentsOf: slot.session.room.remoteParticipants.values
            .map { CCRosterMember(participant: $0) }
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
        case .avatar: "Avatar"
        case .broadcast: "本人"          // 会被 bot 名字盖掉，见 CCRosterMember
        case .agent: "助手"
        case .guest: "访客"
        }
    }

    /// 这个牌子对应哪个角色 —— 有的才能长按换图、双击开 Avatar。
    ///
    /// Chris 2026-09-18：「长按语音助手和长按 Bunny 都能上传一个照片。」
    /// 「双击 bunny 可以打开 Avatar……双击语音助手的时候，这个 Avatar 就会
    /// 变成语音助手开。」
    ///
    /// **「Avatar」那块牌子自己不给** —— 它是渲染出来的**结果**，不是输入。
    /// 手势挂在它身上会让人以为改的是「当前这段视频」；而且它开着才在，
    /// 关掉之后那块牌子就没了，用来关它的手势会跟着一起消失。
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

    // ⚠️ **牌子上没有第二行小字了，整个 detail 都删掉了。**
    //
    // 原来助手那行写 `lk.agent.state` 的英文原值（listening/speaking），
    // Avatar 那行写 `cc.avatar.state`（开/关）。Chris 2026-09-18 两条都砍：
    //
    //   「语音助手 listening 就太长了，光叫语音助手就完了呗。」
    //   「那个开就没必要 —— 你要没开，Avatar 不会出现在这个窗口里。
    //     只要它出现，就说明开了。」
    //
    // 第二句是对的，而且比省地方更值钱：**它的存在本身就是状态**。
    // 再写一个 on 是把同一件事说两遍，而两遍还可能不一致
    // （属性更新和参与者进出不是一个时序）—— 那时候人该信哪个？
    // 顺带把喂它的那整套 `avatarState()` 全房扫描也删了。

    init(id: String, role: CCRosterRole, title: String, speaking: Bool) {
        self.id = id
        self.role = role
        self.title = title
        self.speaking = speaking
    }

    init(participant: Participant) {
        let attrs = participant.attributes
        let ident = participant.identity?.stringValue ?? "?"

        // ⚠️ Avatar必须**排在旁路前面**判：两者都带 lk.publish_on_behalf。
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

        // 本人那一路显示 bot 自己的名字，不写「播报」—— 那是实现细节。
        // identity 形如 `bunny-speaker`，砍掉后缀就是名字。
        var title = role.title
        if role == .broadcast {
            let base = ident.hasSuffix("-speaker")
                ? String(ident.dropLast("-speaker".count)) : ident
            if !base.isEmpty { title = base.prefix(1).uppercased() + base.dropFirst() }
        }

        self.init(id: ident, role: role, title: title, speaking: speaking)
    }
}

extension CCPersonaRole: Identifiable {
    var id: String { rawValue }
}

// MARK: - 单个成员牌子

private struct CCRosterChip: View {
    let member: CCRosterMember
    let room: String
    let persona: CCPersona
    let link: CCAvatarLink
    let onTapPersona: () -> Void

    /// 这个牌子有没有自己的一张脸。没有的（我 / Avatar / 访客）就还画图标。
    private var personaRole: CCPersonaRole? { member.role.personaRole }
    private var thumb: Image? {
        personaRole.flatMap { persona.images[$0.key(room: room)] }
    }
    private var busy: Bool {
        personaRole.map { persona.uploading.contains($0.key(room: room)) } ?? false
    }

    /// 这个角色的 Avatar 开关拨着没有。
    private var avatarOn: Bool {
        personaRole.map { link.wants(room: room).contains($0) } ?? false
    }

    /// 开着、但这一路其实没起来。
    ///
    /// 两种都算：服务端明说 `unavailable`，或者**我们的开关根本没报上去**
    /// （token 少权限那种持续性失败）。后者更阴 —— 两边都不报错，
    /// 服务端只是永远读不到属性，现象就是「双击了没反应」。
    ///
    /// ⚠️ `serverState` 目前是**全房一份**，还分不到角色。所以两个角色都开着时
    /// 这个橙色会同时出现在两块牌子上。等服务端按角色回报再收窄；
    /// 现在宁可多报一个，也好过让一路静默地不工作。
    private var avatarTrouble: Bool {
        guard avatarOn else { return false }
        return link.serverState.shouldSurfaceProblem(userWants: true)
            || link.lastPublishError != nil
    }

    var body: some View {
        HStack(spacing: 5) {
            // 只判「有没有脸」，不需要解包出来的值 —— 里面用的是 thumb / busy，
            // `if let` 会留一个没人用的绑定，编译器直接报 warning。
            if personaRole != nil {
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
            } else {
                Image(systemName: member.role.symbol)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(verbatim: member.title)
                .font(.system(size: 12, weight: .medium))
            // ⭐ Avatar 开着的标记。Chris 2026-09-18：「在 Bunny 头上放一个
            //    标记的图标，像是什么小屏幕之类的这种。」
            //
            //    放在名字**后面**而不是压在缩略图角上：牌子只有 34pt 高，
            //    角标要么被胶囊边缘切掉，要么得溢出去压住隔壁那块牌子。
            //
            //    ⚠️ 这个标记也是**唯一**能看出开关状态的地方 —— 双击是个
            //    没有视觉提示的手势，标记要是不明显，用户按完只能靠等画面
            //    来确认，而画面要好几秒才出来。
            if avatarOn {
                Image(systemName: "display")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(avatarTrouble ? .orange : .green)
                    .transition(.scale.combined(with: .opacity))
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
        .ccAnimation(.snappy, value: avatarOn)
        .modifier(CCChipGestures(room: room, role: personaRole,
                                 persona: persona, link: link,
                                 onPreview: onTapPersona))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [
            member.title,
            member.speaking ? "正在说话" : nil,
            avatarOn ? (avatarTrouble ? "Avatar 已开但没起来" : "Avatar 已开") : nil,
        ].compactMap { $0 }.joined(separator: "，")))
        .accessibilityHint(Text(verbatim:
            personaRole == nil ? "" : "轻点头像放大，双击开关 Avatar，长按换一张"))
    }
}

// MARK: - 牌子上的三个手势

/// 一块牌子上的全部手势：**单击看大图、双击开关 Avatar、长按换图**。
///
/// 三个收在一个 modifier 里，是因为它们共享同一条前提 —— `role == nil`
/// （我 / Avatar / 访客那几块牌子）就**一个都不挂**。分散在各处写的话，
/// 迟早有一个漏掉那层判断，变成一个按了没反应的手势，而那比没有更让人困惑。
///
/// 长按那部分单独 `#if os(iOS)`：`PhotosPicker` 只有 iOS 有，
/// 而 macOS / visionOS 那两个 target 也要能编过。两个 tap 是全平台的。
private struct CCChipGestures: ViewModifier {
    let room: String
    /// nil = 这个牌子没有自己的角色，整组手势都不挂。
    let role: CCPersonaRole?
    let persona: CCPersona
    let link: CCAvatarLink
    let onPreview: () -> Void

    #if os(iOS)
        @State private var pick: PhotosPickerItem?
        @State private var showing = false
    #endif

    // ⚠️ 两个分支返回的类型不一样（挂了手势的 vs 原样），必须 @ViewBuilder。
    @ViewBuilder
    func body(content: Content) -> some View {
        if let role { attach(content, role: role) } else { content }
    }

    @ViewBuilder
    private func attach(_ content: Content, role: CCPersonaRole) -> some View {
        // ⚠️⚠️ **双击必须声明在单击前面。** SwiftUI 按声明顺序定优先级，
        //      反过来写的话单击会先吃掉第一下，双击永远等不到第二下 ——
        //      表现是「双击 Bunny 弹出了两次大图，Avatar 没开」。
        //      这个顺序没有编译期保护，改这段时先回来看这一行。
        let tapped = content
            .onTapGesture(count: 2) {
                CCHaptics.toggleAvatar()
                link.toggle(room: room, role: role)
            }
            .onTapGesture(count: 1, perform: onPreview)

        #if os(iOS)
            tapped
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
        #else
            tapped
        #endif
    }
}

// MARK: - 放大看

private struct CCPersonaPreview: View {
    let room: String
    let role: CCPersonaRole
    let persona: CCPersona
    @Environment(\.dismiss) private var dismiss

    private var key: String { role.key(room: room) }
    private var who: String { role.title }

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
