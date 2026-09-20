import SwiftUI

/// 人名牌子下面那条状态带：**一眼看完整个任务树。**
///
/// Chris 2026-09-20 定的形状：
///
/// > 挪上边去，紧挨着房间里三个 agent 下边。显示状态、任务摘要和执行时长。
/// > 如果启动了 sub agent 和 backend agent，下面再加行 —— 几杠几、
/// > 在干啥（摘要）、运行时长。这不就对整个任务和过程有一个概览？
///
/// ```
///  ● 在忙   把今天的 commit 过一遍写成时间线        1:24
///    子 1/2  查 LiveKit 属性上限                    0:42
///    子 2/2  盘点两个仓库的改动                     1:08
///    后台 1/1 跑离线编译                            3:41
/// ```
///
/// ## 三条设计判断
///
/// 1. **它从中间那块大屏挪到了顶上。** 原来占着数字人的位置，
///    于是「有数字人时显示数字人、没有时显示状态」要二选一 ——
///    而这两样根本不冲突。挪上来之后中间还给数字人/柱子，两边都在。
///    顺带解决了那个「文字压在人名牌子上」的老问题：它现在**在牌子下面**，
///    不再是浮在主画面上的 overlay。
///
/// 2. **每行三段：是谁 / 在干啥 / 多久了。** 不再有计数胶囊、
///    不再有滚动流水 —— 那些是「看着热闹」，而这三段是**你真正要做决定时
///    需要的东西**：要不要去看一眼、卡住的是哪一支、卡了多久。
///
/// 3. **几杠几比总数有用。** 「子 2/3」告诉你它是第二个、一共三个；
///    单写「3 个子 agent」你还得自己数到哪了。
struct CCBotStatusStrip: View {
    var status: CCBotStatus

    /// 计时用。服务端那个 `sec` 是发出那一刻的值，本地往前推才连续。
    @State private var now = Date.now
    @State private var seenAt = Date.now
    /// 定时器起点。**必须存下来，不能每次写 `.now`** ——
    /// `.periodic` 的第一个刻度就是 `from` 本身，每次重算都取新值的话
    /// 每次重建都立刻自触发一跳，闭环死循环。（2026-09-20 踩过）
    @State private var epoch = Date.now

    private static let tick: TimeInterval = 1.0

    private var snap: CCBotStatus.Snapshot? { status.snap }

    var body: some View {
        if let s = snap {
            VStack(alignment: .leading, spacing: 3) {
                mainLine(s)
                ForEach(rows(s)) { r in subLine(r) }
                if s.unlinked > 0 {
                    // ⚠️ 不能藏：它不为 0 就说明上面那几行是不全的。
                    Text(verbatim: "＋\(s.unlinked) 条没归到具体哪一支")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.leading, 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(borderTint, lineWidth: waiting ? 1.5 : 0.5)
            }
            .padding(.horizontal, 8)
            .overlay { if s.on { sampler } }
        }
    }

    // MARK: - 主任务那一行

    @ViewBuilder
    private func mainLine(_ s: CCBotStatus.Snapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .offset(y: -1)
            Text(verbatim: state(s))
                .font(.caption).bold()
                .foregroundStyle(waiting ? Color.orange : .primary)
                .fixedSize()
            Text(verbatim: s.act.isEmpty ? "—" : s.act)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            clock(elapsed(s))
        }
    }

    /// 左边那个短词。**只放状态，不放内容** —— 内容在它右边那一格。
    private func state(_ s: CCBotStatus.Snapshot) -> String {
        if !s.wait.isEmpty { return s.wait }   // 「等你批准方案」之类
        return s.on ? "在忙" : "空闲"
    }

    // MARK: - 子 agent / 后台 各占一行

    /// 一行的数据。**几杠几在这里算好** —— 子 agent 和后台各自从 1 开始编号。
    private struct Row: Identifiable {
        let id: String
        let label: String      // 「子 2/3」/「后台 1/1」
        let summary: String
        let seconds: Double
        let st: String
    }

    private func rows(_ s: CCBotStatus.Snapshot) -> [Row] {
        let subs = s.tasks.filter(\.sub)
        let bgs  = s.tasks.filter { !$0.sub }
        func make(_ list: [CCBotStatus.Job], _ name: String) -> [Row] {
            list.enumerated().map { i, t in
                Row(id: name + t.id,
                    label: "\(name) \(i + 1)/\(list.count)",
                    summary: summary(t),
                    seconds: t.sec,
                    st: t.st)
            }
        }
        return make(subs, "子") + make(bgs, "后台")
    }

    /// 这一支的**任务摘要**。
    ///
    /// 跑着的时候用「派它去干什么」，干完了用那句收尾摘要 ——
    /// 跑完之后「在读 x.py」已经是过去式，而收尾那句才说明它到底做成了什么。
    private func summary(_ t: CCBotStatus.Job) -> String {
        if t.st == "running" {
            return t.what.isEmpty ? (t.act.isEmpty ? t.kind : t.act) : t.what
        }
        return t.sum.isEmpty ? (t.what.isEmpty ? t.kind : t.what) : t.sum
    }

    private func subLine(_ r: Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon(r.st))
                .font(.system(size: 9))
                .foregroundStyle(color(r.st))
                .frame(width: 7)
            Text(verbatim: r.label)
                .font(.caption2).bold()
                .foregroundStyle(color(r.st))
                .fixedSize()
            Text(verbatim: r.summary.isEmpty ? "—" : r.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            clock(r.seconds, small: true)
        }
    }

    // MARK: - 计时

    /// 服务端给的秒数 ＋ 从收到那一刻到现在。
    /// 状态限频而且没变就不发，一条跑三分钟的命令期间那个数一动不动 ——
    /// 本地补这一段，计时才是连续的。
    private func elapsed(_ s: CCBotStatus.Snapshot) -> Double {
        guard s.on else { return s.sec }      // 结束了就冻住
        return s.sec + now.timeIntervalSince(seenAt)
    }

    private func clock(_ t: Double, small: Bool = false) -> some View {
        let n = max(0, Int(t.rounded()))
        return Text(verbatim: n < 60 ? "\(n)s" : String(format: "%d:%02d", n / 60, n % 60))
            .font(.system(small ? .caption2 : .caption, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .fixedSize()
    }

    /// **只在「在忙」时才挂** —— 空闲时秒数是冻住的，跳了也改变不了任何像素。
    private var sampler: some View {
        TimelineView(.periodic(from: epoch, by: Self.tick)) { ctx in
            Color.clear
                .allowsHitTesting(false)
                .onChange(of: ctx.date) { _, d in now = d }
                .onChange(of: snapKey) { _, _ in
                    seenAt = Date.now
                    now = Date.now
                }
        }
    }

    /// 判断「这是不是一份新状态」。不直接比整个 Snapshot：那样流水一到也会
    /// 触发，而流水不该重置计时基准。
    private var snapKey: String {
        guard let s = snap else { return "" }
        return "\(s.on)|\(s.act)|\(s.wait)|\(s.sec)|\(s.tasks.count)"
    }

    // MARK: - 样式

    private var waiting: Bool { !(snap?.wait ?? "").isEmpty }

    private var dotColor: Color {
        guard let s = snap else { return .gray }
        if !s.wait.isEmpty { return .orange }
        return s.on ? .green : .gray
    }

    private var borderTint: Color {
        waiting ? .orange : Color.primary.opacity(0.12)
    }

    private func icon(_ st: String) -> String {
        switch st {
        case "running": "circle.dotted"
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        // 收尾事件没收到。**不给绿勾** —— 我们并不知道它成没成。
        default: "questionmark.circle"
        }
    }

    private func color(_ st: String) -> Color {
        switch st {
        case "running": .blue
        case "completed": .green
        case "failed": .red
        default: .orange
        }
    }
}
