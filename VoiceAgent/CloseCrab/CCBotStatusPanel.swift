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
    @ObservedObject private var status = CCBotStatus.shared

    /// 计时用。**必须自己驱动重算** —— `sec` 是服务端发的那一刻的值，
    /// 没有新属性进来它就不会变，而人要看的是「到现在多久了」。
    @State private var now = Date.now
    /// 最后一次收到状态的本地时刻，用来把服务端那个 `sec` 往前推。
    @State private var seenAt = Date.now
    @State private var lastSnapID: String = ""

    private static let tick: TimeInterval = 1.0

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
        VStack(alignment: .leading, spacing: 14) {
            header
            if let s = snap {
                if !s.act.isEmpty && s.on { activityLine(s) }
                if !s.tasks.isEmpty { taskList(s) }
                if s.unlinked > 0 { unlinkedNote(s) }
            }
            Spacer(minLength: 0)
            if !status.steps.isEmpty { stepTail }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(panelTint, in: RoundedRectangle(cornerRadius: 18))
        .overlay(sampler)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .symbolEffect(.pulse, isActive: snap?.on == true)
            Text(verbatim: snap?.headline ?? "还没收到状态")
                .font(.headline)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(verbatim: clock(elapsed))
                .font(.system(.title3, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func activityLine(_ s: CCBotStatus.Snapshot) -> some View {
        Text(verbatim: s.act)
            .font(.title3)
            .lineLimit(2)
            .foregroundStyle(.primary)
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

    private func taskRow(_ t: CCBotStatus.Task) -> some View {
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

    /// 在等人的时候整块换色。**这是唯一需要你动手的状态**，
    /// 跟「它自己在忙」必须一眼分得开。
    private var panelTint: Color {
        guard let s = snap, !s.wait.isEmpty else { return Color.primary.opacity(0.05) }
        return Color.orange.opacity(0.14)
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
        TimelineView(.periodic(from: .now, by: Self.tick)) { ctx in
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
