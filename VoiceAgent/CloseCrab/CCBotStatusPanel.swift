import SwiftUI

/// 中间那块屏：**bot 此刻在忙什么。**
///
/// 数字人放不了的时候占这块地方（见 `CCBotStatus` 的类文档）。
///
/// ## 五条设计判断
///
/// 1. **计时永远在走。** 这块屏上最有用的一个数就是「已经多久了」——
///    它是你决定「要不要去看一眼」的唯一依据。所以它每秒刷，
///    哪怕别的什么都没变。
///
/// 2. **不知道就显示不知道。** 子 agent 收尾事件没收到时，服务端标的是
///    `unknown` 不是 `completed`。界面照着显示 —— 问号，不是绿勾。
///    实测两条后台任务里就有一条是 `unknown`，**这不是罕见情况**。
///
/// 3. **子 agent 和后台命令分开。** 混在一起的话跑一条后台命令屏幕上就多
///    一个假的子 agent。服务端上线第一分钟就被真实数据抓到过这个。
///
/// 4. **空闲不空屏。** 一轮结束之后显示上一轮的收尾（跑了多久、派了几个），
///    而不是变成一块白板。白板会让人以为断了。
///
/// 5. **流水只留最后几行，而且淡。** 它是氛围不是信息 —— 真要看细节去看
///    飞书。这里多了就是刷屏，而刷屏的屏幕人会直接不看。
struct CCBotStatusPanel: View {
    /// **这一页那个房间的**状态。由 `AgentView` 从自己的槽位取出来传进来 ——
    /// 曾经是 `CCBotStatus.shared`，那会让 A 房间的状态显示在 B 房间的屏上。
    var status: CCBotStatus

    /// 计时用。**必须自己驱动重算** —— `sec` 是服务端发的那一刻的值，
    /// 没有新属性进来它就不会变，而人要看的是「到现在多久了」。
    @State private var now = Date.now
    /// 最后一次收到状态的本地时刻，用来把服务端那个 `sec` 往前推。
    @State private var seenAt = Date.now

    private static let tick: TimeInterval = 1.0

    /// 定时器的起点。**必须是存下来的固定值，不能每次写 `.now`。**
    ///
    /// ⛔ 这是 2026-09-20「一从空闲变在忙就卡死、而且再也回不来」的真因：
    ///
    /// `.periodic(from:by:)` 的**第一个刻度就是 `from` 本身**。写成 `from: .now`
    /// 的话，每次重算 body 都会取一次当前时间当起点 —— 于是**每次重建都立刻
    /// 触发一跳**，那一跳又回写 `@State`，回写又触发重建。闭环，而且是死的。
    ///
    /// 为什么只在「在忙」时才发作：SwiftUI 按**读取**建依赖。空闲时那个时刻值
    /// 根本没被读到，写它不会让 body 失效，环就合不上；一变在忙就读了，
    /// 环当场闭合。`AgentView` 那个采样器是**一模一样的形状**，
    /// 只是它的条件（数字人正在说话）平时不成立，所以一直没发作。
    ///
    /// 存成 `@State` 之后起点不动了：重建之后当前刻度还是同一个值，
    /// `onChange` 不会被触发，环断开。
    @State private var epoch = Date.now

    private var snap: CCBotStatus.Snapshot? { status.snap }

    /// 服务端给的秒数 ＋ 从收到那一刻到现在。
    ///
    /// ⚠️ 不能只显示服务端那个 `sec`：状态限频 0.5 秒一次、而且**没变就不发**，
    /// 一个跑了三分钟的长命令期间那个数会一动不动。本地补这一段，
    /// 计时才是连续的。
    private var elapsed: TimeInterval {
        guard let s = snap else { return 0 }
        guard s.on else { return s.sec }        // 结束了就冻住
        return s.sec + now.timeIntervalSince(seenAt)
    }

    var body: some View {

        let _ = CCProbe.tick("StatusPanel")   // 探针，定位完删
        VStack(alignment: .leading, spacing: 12) {
            header
            if let s = snap {
                if !detail.isEmpty && s.on { activityLine }
                if !s.tasks.isEmpty { taskList(s) }
                if s.unlinked > 0 { unlinkedNote(s) }
            }
            if !status.steps.isEmpty { stepTail }
        }
        .padding(16)
        // ⚠️ **只占内容需要的高度，不要 `maxHeight: .infinity`。**
        //    撑满会把内容顶到画面最上沿，而那儿被 `CCRosterRow` 那排人名牌子
        //    盖着 —— 它是 overlay，不占位置。2026-09-20 真机截图上文字就是
        //    直接压在「我 / 语音助手 / Jarvis」那几个牌子上的。
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(borderTint, lineWidth: waiting ? 1.5 : 0.5)
        }
        // 让开那排浮在上面的牌子。高度从 `CCRosterRow.height` 取，
        // **别在这儿另写一个 44** —— 两处不一致就会又压上去。
        // ＋8 是留口气，不然卡片上沿正好贴着牌子下沿，看着像粘在一起。
        .padding(.top, CCRosterRow.height + 8)
        .padding(.horizontal, 4)
        // ⚠️ **只在「在忙」时才挂。** 空闲时 `elapsed` 返回冻住的 `s.sec`，
        //    根本不读 `now` —— 定时器跳了也改变不了屏上任何一个像素。
        .overlay { if snap?.on == true { sampler } }
    }

    // MARK: - 顶部

    /// 在等人的时候，标题就是「在等什么」。
    private var waiting: Bool { !(snap?.wait ?? "").isEmpty }

    /// 整句多长就拆成「动词 ＋ 一行小字」。
    ///
    /// ⚠️ 不拆的话：服务端给的是一整句「在跑 cd ~/CloseCrab && grep …」，
    /// 一条命令几十个字符，在标题字号下会把右边的计时**整个挤出屏幕**，
    /// 而且尾巴直接被屏幕边缘切掉、连省略号都没有。2026-09-20 真机截图上
    /// 就是这样 —— 看不到跑了多久，而那是这块屏最有用的一个数。
    ///
    /// 但**短的不拆**：「在读 agent_state.py」拆成「在读」＋一行小字反而更难看。
    private static let inlineLimit = 18

    /// 这一句要不要拆。
    private var splits: Bool {
        guard let s = snap, s.on, !waiting else { return false }
        return s.act.count > Self.inlineLimit && s.act.contains(" ")
    }

    private var verb: String {
        guard let s = snap else { return "还没收到状态" }
        if waiting { return s.wait }
        guard s.on else { return "空闲" }
        if s.act.isEmpty { return "在忙" }
        guard splits, let i = s.act.firstIndex(of: " ") else { return s.act }
        return String(s.act[s.act.startIndex ..< i])
    }

    /// 动词后面那一长串（文件名、命令、搜索词）。不拆的时候是空串。
    private var detail: String {
        guard splits, let s = snap, let i = s.act.firstIndex(of: " ") else { return "" }
        return String(s.act[s.act.index(after: i)...])
            .trimmingCharacters(in: .whitespaces)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .offset(y: -1)
            Text(verbatim: verb)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            // ⚠️ `fixedSize` ＋ 高 `layoutPriority`：计时**永远不许被挤掉**。
            //    它是这块屏上最有用的那个数。
            Text(verbatim: clock(elapsed))
                .font(.system(.subheadline, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .layoutPriority(1)
        }
    }

    /// 长的那一串。等宽字体 —— 它多半是路径或者命令，等宽更好扫。
    /// 中间截断而不是尾部：路径和命令的**结尾往往才是有信息的那一端**。
    private var activityLine: some View {
        Text(verbatim: detail)
            .font(.system(.footnote, design: .monospaced))
            .lineLimit(2)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 子 agent / 后台

    @ViewBuilder
    private func taskList(_ s: CCBotStatus.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                countChip("子 agent", s.subs, tint: .blue)
                if s.bg.run + s.bg.done > 0 {
                    countChip("后台", s.bg, tint: .gray)
                }
            }
            ForEach(s.tasks.filter(\.sub)) { t in taskRow(t) }
        }
    }

    private func countChip(_ label: String, _ c: CCBotStatus.Counts,
                           tint: Color) -> some View {
        Text(verbatim: "\(label) \(c.run) 跑 / \(c.done) 完")
            .font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private func taskRow(_ t: CCBotStatus.Job) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: t.st))
                .font(.caption)
                .foregroundStyle(color(for: t.st))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: t.what.isEmpty ? (t.kind.isEmpty ? "子 agent" : t.kind) : t.what)
                    .font(.subheadline)
                    .lineLimit(1)
                // 跑着的时候显示「此刻在干啥」，干完了显示那句摘要。
                // 两者不会同时有用 —— 跑完之后「在读 x.py」已经是过去式。
                let detail = t.st == "running" ? t.act : t.sum
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Text(verbatim: clock(t.sec))
                .font(.caption).monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    /// ⚠️ 这一条**不能藏**。它不为 0 就说明上面那份子 agent 列表是不完整的 ——
    /// 有些动作我们没能挂到任何一条任务上。藏起来的话屏幕会安静地少一块，
    /// 而看的人完全不知道少了。
    private func unlinkedNote(_ s: CCBotStatus.Snapshot) -> some View {
        Text(verbatim: "另有 \(s.unlinked) 条动作没能归到具体哪个子 agent")
            .font(.caption2)
            .foregroundStyle(.orange)
    }

    // MARK: - 流水

    private var stepTail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(status.steps.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.caption2).monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 样式

    private var dotColor: Color {
        guard let s = snap else { return .gray }
        if !s.wait.isEmpty { return .orange }
        return s.on ? .green : .gray
    }

    /// 在等人的时候把边框点亮成橘色。**这是唯一需要你动手的状态**，
    /// 跟「它自己在忙」必须一眼分得开。
    ///
    /// 改成描边而不是整块填充：底子现在是 `.regularMaterial`（毛玻璃），
    /// 再叠一层半透明橘色会把材质压成一块脏颜色。
    /// 原来那个 `Color.primary.opacity(0.05)` 在浅色背景上**几乎看不见** ——
    /// 真机截图上这块屏根本不像一张卡片，就是一片白。
    private var borderTint: Color {
        waiting ? .orange : Color.primary.opacity(0.12)
    }

    private func icon(for st: String) -> String {
        switch st {
        case "running": "circle.dotted"
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        // 收尾事件没收到。**不给绿勾** —— 我们并不知道它成没成。
        default: "questionmark.circle"
        }
    }

    private func color(for st: String) -> Color {
        switch st {
        case "running": .blue
        case "completed": .green
        case "failed": .red
        default: .orange
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - 采样

    /// ⚠️ **必须定时刷，不能只靠属性到达时重算。**
    ///
    /// 属性限频 0.5 秒、而且没变就不发。一条跑三分钟的命令期间一条都不会来，
    /// 计时就会停在那儿 —— 而那正是你最想知道「它卡了多久」的时候。
    ///
    /// 放 overlay 里而不是包住 body：包住的话每秒整块重建，
    /// 子视图的动画会被打断。
    private var sampler: some View {
        TimelineView(.periodic(from: epoch, by: Self.tick)) { ctx in
            Color.clear
                .onChange(of: ctx.date) { _, d in now = d }
                .onChange(of: snapKey) { _, _ in
                    // 新的一份状态到了，把本地补时的基准挪到现在。
                    seenAt = Date.now
                    now = Date.now
                }
        }
    }

    /// 用来判断「这是不是一份新状态」。直接比整个 Snapshot 也行，
    /// 但那会在每条流水到达时也触发 —— 而流水不该重置计时基准。
    private var snapKey: String {
        guard let s = snap else { return "" }
        return "\(s.on)|\(s.act)|\(s.wait)|\(s.sec)|\(s.subs.run)|\(s.subs.done)"
    }
}
