import SwiftUI

/// 主界面的快捷回复：bot「等你回话」时浮在「按住说话」长条上方。
///
/// ```
///        等你批准方案                      ← bot 等的那句（wait / <ask-user> 摘要）
///  [ ✓ 没问题，请继续 ] [ 👍 按照你的想法来 ]
///  [            🎙 按住说话              ]
///  [  控制栏 …                           ]
/// ```
///
/// Chris 2026-10-05：「快捷回复先在 app 主界面做好，锁屏卡片只是复用。」
/// 判定全在 `CCQuickReply.display`（纯 Foundation、离线测过，锁屏卡片用同一份）；
/// 发出去走 `CCQuickReplySender`（app 的文字通道 `session.send(text:)`，跟聊天框同一条）。
///
/// ## 样子
///
/// 两颗按钮跟说话条 / 控制栏**同一套**：同高（`CC.Size.bar`）、同圆角、iOS 上 Liquid Glass、
/// Mac 上平面填充（`ccFlatBar`）。放在同一个 `GlassEffectContainer` 里，出现 / 消失时
/// 跟下面那条互相融进融出，不是各弹各的。
///
/// 按下去立刻收起、换成一行「已回复：<完整原句>」3 秒；状态离开「等你」就整块消失。
/// 放不下整句时按钮上显示简写（「请继续」「按你的来」），**发出去的永远是整句**。
struct CCQuickReplyBar: View {
    let slot: CCRoomSlot
    let presence: CCPresenceDot

    /// 「已回复」到点要撤下 —— 这不是属性变化，靠这个 tick 让 body 再算一次。
    @State private var tick = 0

    private func display(now: Date) -> CCQuickReply.Display {
        let snap = slot.botStatus.snap
        let mood = CCFaceMood.derive(
            presence: presence,
            botPresent: slot.botPresent,
            wait: snap?.wait ?? "",
            on: snap?.on ?? false,
            holding: slot.micPolicy.isHolding,
            speaking: slot.isSpeaking,
            muted: slot.isMuted,
            finishedAt: slot.botStatus.finishedAt,
            speechEndedAt: slot.speechEndedAt,
            now: now)
        return CCQuickReply.display(mood: mood, wait: snap?.wait ?? "",
                                    repliedText: slot.quickReply.repliedText,
                                    repliedAt: slot.quickReply.repliedAt, now: now)
    }

    var body: some View {
        let _ = tick
        let shown = display(now: .now)
        Group {
            switch shown {
            case .hidden:
                EmptyView()
            case let .replied(line):
                Text(verbatim: line)
                    .font(CC.Font.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            case let .offer(prompt):
                VStack(spacing: CC.Space.tight) {
                    if !prompt.isEmpty {
                        Text(verbatim: prompt)
                            .font(CC.Font.label)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    // bot 带了推荐答案就是它的，没带就是固定那两句（`CCQuickReply.choices(options:labels:)`）。
                    // 2~4 颗都排一行（Chris 2026-10-06）；超过两颗时不画图标、间距收紧，宽度留给字。
                    let choices = CCQuickReply.choices(options: slot.botStatus.snap?.opts,
                                                       labels: slot.botStatus.snap?.optl)
                    let roomy = choices.count <= 2
                    HStack(spacing: roomy ? CC.Space.snug : CC.Space.tight) {
                        ForEach(choices, id: \.self) { c in
                            button(c, icon: roomy)
                        }
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ccAnimation(CC.Motion.fade, value: shown)
        // 「已回复」窗口到点撤下：睡到 3 秒整再让 body 重算一次。id 换了（又点了一次）就重排。
        .task(id: slot.quickReply.repliedAt) {
            guard let t = CCQuickReply.repliedRecheck(at: slot.quickReply.repliedAt, now: .now) else { return }
            try? await Task.sleep(for: .seconds(max(0, t.timeIntervalSinceNow) + 0.05))
            tick &+= 1
        }
        if let err = slot.quickReply.lastError, shown != .hidden {
            Text(verbatim: err)
                .font(CC.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func button(_ c: CCQuickReply.Choice, icon: Bool) -> some View {
        Button {
            Task { await slot.quickReply.send(c.text) }
        } label: {
            // 先试整句，放不下再用简写 —— 同高，换了不跳。
            // 最后一档不定宽、截断显示 —— bot 没给短标签（或短标签也放不下）时
            // 前两档都是定宽的，ViewThatFits 会拿最后一档硬塞，定宽的话就溢出按钮。
            ViewThatFits(in: .horizontal) {
                label(c.text, icon ? c.symbol : nil)
                label(c.short, icon ? c.symbol : nil)
                label(c.short, icon ? c.symbol : nil, fixed: false)
            }
            .frame(maxWidth: .infinity)
            .frame(height: CC.Size.bar)
            .contentShape(.cc(CC.Radius.bar))
        }
        .buttonStyle(.plain)
        #if os(macOS)
            .ccFlatBar(radius: CC.Radius.bar)
        #else
            .glassEffect(.regular.interactive(), in: .cc(CC.Radius.bar))
        #endif
        // 读屏念完整原句（简写只是视觉上的退让）。
        .accessibilityLabel(Text(verbatim: c.text))
    }

    private func label(_ title: String, _ symbol: String?, fixed: Bool = true) -> some View {
        HStack(spacing: CC.Space.tight) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
            }
            Text(verbatim: title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(fixed ? 1 : 0.8)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, symbol == nil ? CC.Space.tight : CC.Space.snug)
        .fixedSize(horizontal: fixed, vertical: fixed)
    }
}
