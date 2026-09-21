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

    /// 一次拖多少。**用比例不用秒数** —— 服务端收的就是比例（-1…1），
    /// 而且一段话可能 3 秒也可能 3 分钟，固定秒数在两头都不好用。
    private let step = 0.15

    var body: some View {
        VStack(spacing: CC.Space.tight) {
            progress
            buttons
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
        .onAppear { remote.startPolling() }
        .onDisappear { remote.stopPolling() }
    }

    // MARK: -

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
            key("arrow.counterclockwise", "重播") { await remote.replay() }
            key("gobackward", "后退") { await remote.seek(-step) }

            // 中间这颗大一号，见类型注释。
            key(remote.isActive ? "pause.fill" : "play.fill",
                remote.isActive ? "暂停" : "继续",
                size: 18) {
                if remote.isActive { await remote.pause() } else { await remote.resume() }
            }

            key("goforward", "前进") { await remote.seek(step) }
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
