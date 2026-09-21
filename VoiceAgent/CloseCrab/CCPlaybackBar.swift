import LiveKit
import SwiftUI

/// bot 说话时浮出来的一条播放控制 —— 跟飞书卡片上那五颗是同一个播放器。
///
/// ## 只在真的在播的时候出现
///
/// 常驻一条「停止 / 暂停」的灰按钮，等于每一眼都在提示一个多数时候用不上的功能
/// （同族：`feedback_normal-disguised-as-failure`，默认状态不该长得像待办）。
/// 所以它挂在 `isActive` 上，不播就整条不存在，连轮询都停掉。
///
/// ## 五颗按钮的排法
///
/// ```
///   ↺      ⤺15%    ⏸/▶     ⤼15%      ✕
///  重播    后退     暂停     前进     停止
/// ```
///
/// 中间那颗最大 —— 暂停/继续是**唯一会被反复按**的那个，
/// 其余四颗是偶尔用一次。按频率给尺寸，不给一样大。
struct CCPlaybackBar: View {
    let remote: CCPlaybackRemote

    /// 看不见就别轮询 —— 见 `CCRenderGate`。
    @Environment(\.ccRendering) private var rendering

    /// 一次拖多少。**用比例不用秒数** —— 服务端收的就是比例（-1…1），
    /// 而且一段话可能 3 秒也可能 3 分钟，固定秒数在两头都不好用。
    private let step = 0.15

    var body: some View {
        VStack(spacing: CC.Space.tight) {
            // 播完之后收成一颗「重播」。
            //
            // ## 为什么不是保留整条
            //
            // 播完之后暂停/前进/后退都没有意义（按下去服务端会回 `ok:false`），
            // 摆五颗灰按钮只是在告诉人「这儿有四个不能用的东西」。
            // 而**重播是这时候唯一有意义、而且最高频的动作** ——
            // Chris 的原话是「刚才那一段没听懂，我再点重播，再听一遍」。
            //
            // ⚠️ 它会一直挂在那儿直到下一段开始或者被停掉。
            // 这看起来违反「默认状态不该长得像待办」，但这里是反的：
            // **它不是待办，它是一个随时可用的入口**，而且是被明确要过的。
            if !remote.isActive, remote.canReplay {
                replayOnly
            } else {
                progress
                buttons
            }
            if let err = remote.lastError {
                // ⚠️ **失败必须看得见。** 遥控失败如果是静默的，
                //    用户只会觉得「这按钮有时候不灵」，而那种印象修不回来。
                Text(verbatim: err)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, CC.Space.snug)
        .padding(.vertical, CC.Space.tight)
        .background(.regularMaterial, in: Capsule())
        // ⭐ 轮询也归渲染闸门管：看不见的房间/锁着的屏，
        //    进度拉回来也没人看，而每次都是一趟 RPC 往返。
        .onAppear { if rendering { remote.startPolling() } }
        .onDisappear { remote.stopPolling() }
        .onChange(of: rendering) { _, on in
            if on { remote.startPolling() } else { remote.stopPolling() }
        }
    }

    // MARK: -

    /// 播完之后那一颗。带上时长 —— 光一个图标看不出「重播多久的东西」。
    private var replayOnly: some View {
        Button {
            Task { await remote.replay() }
        } label: {
            HStack(spacing: CC.Space.tight) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .medium))
                Text(verbatim: "重播")
                    .font(.system(size: 12, weight: .medium))
                if let total = remote.total, total > 0 {
                    Text(verbatim: clock(total))
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "重播刚才那一段"))
    }

    /// 进度。
    ///
    /// ⚠️ **总长未知时不画进度条，只报已播秒数。**
    /// 服务端在音频还在生成时会如实回 `total: null`（它的注释写着「别编一个分母」）。
    /// 这边要是拿一个猜的分母去画，用户会看到「快播完了」而其实刚开始 ——
    /// **一个骗人的进度条比没有进度条坏得多**，因为它看起来是有信息的。
    @ViewBuilder
    private var progress: some View {
        if let total = remote.total, total > 0 {
            HStack(spacing: CC.Space.tight) {
                Text(verbatim: clock(remote.played))
                ProgressView(value: min(remote.played / total, 1))
                    .frame(maxWidth: 140)
                Text(verbatim: clock(total))
            }
            .font(.system(size: 10, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        } else {
            Text(verbatim: "\(clock(remote.played))  · 生成中")
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: CC.Space.snug) {
            // ⚠️ 重播、后退、前进**不能都用转圈箭头**。
            //    第一版是 `arrow.counterclockwise` / `gobackward` / `goforward`，
            //    三个都是圆弧箭头，在 13pt 下几乎分不出来
            //    —— Chris 那张截图里前两颗看着就是同一个东西。
            //    现在拖动用双三角（所有播放器的通用语汇），只有重播是圆弧。
            key("arrow.counterclockwise", "重播") { await remote.replay() }
            key("backward.fill", "后退") { await remote.seek(-step) }

            // 中间这颗大一号，见类型注释。
            //
            // ⚠️ **读 `isPaused`，不是 `!isActive`。** 服务端的 `active`
            //    在暂停时**仍然为真**（播放器还咬着那段音频）。
            //    第一版用它画图标 ⇒ 暂停之后图标不变 ⇒ 找不到继续的入口。
            key(remote.isPaused ? "play.fill" : "pause.fill",
                remote.isPaused ? "继续" : "暂停",
                size: 18) {
                if remote.isPaused { await remote.resume() } else { await remote.pause() }
            }

            key("forward.fill", "前进") { await remote.seek(step) }
            key("xmark", "停止") { await remote.stop() }
        }
    }

    private func key(_ symbol: String, _ label: String, size: CGFloat = 13,
                     action: @escaping () async -> Void) -> some View
    {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                // 图标十几个点，命中区要撑开 —— 否则得瞄准才点得中。
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 那个参与者不在房间里时全部置灰。**不要让人按下去等超时** ——
        // 「按了没反应」和「按了要等一下」在体感上是一回事。
        .disabled(!remote.reachable && remote.lastError != nil)
        .accessibilityLabel(Text(verbatim: label))
        #if os(macOS)
            .help(label)
        #endif
    }

    private func clock(_ t: Double) -> String {
        let n = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", n / 60, n % 60)
    }
}
