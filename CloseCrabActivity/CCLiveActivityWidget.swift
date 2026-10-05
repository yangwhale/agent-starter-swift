import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// 锁屏卡片 ＋ 灵动岛（收起 / 最小 / 展开）。
///
/// 数据全在 `context.state`（`CCLiveActivityState`，app 推过来的）。这里不做判断，
/// 只画 —— 判断都在 app 那边的 `CCLiveActivityPolicy` 里，离线测过。
///
/// ## 长什么样（方案页 `ios-live-activity-plan-20261005`）
///
/// ```
///  ◡ ◡  bunny ●            jarvis ● tommy ●
///       跑 Q10 验收（3 个子任务）
///   0:12 ━━━━━━━━━━━━━━──────────── 0:48
///   [   ⏸ 暂停   ] [   ↺ 重播   ]
/// ```
///
/// 等你回话时最后一行换成 `[ ✓ 没问题，请继续 ] [ ✋ 按照你的想法来 ]`（快捷回复，
/// 走 app 的文字通道发给 bot 本体；按钮放不下整句时显示简写「请继续」「按你的来」）。
///
/// - 脸：按心情选定的**一帧**（实时活动里不能跑连续动画）。同一套形状和身份色金属。
/// - 进度条：bot 有在播 / 能重播的语音时才出现；在播时用系统计时视图自己走，不靠每秒推更新。
///   卡片上**不再有「已查」那个计时**（Chris 2026-10-05 拿掉的，见下面 CCActivityDot 后那段）。
/// - 按钮：**两种音频模式都一直显示**（Chris 2026-10-05 后来简化的：不再按「系统播放控件」
///   开关藏起来）。点下去在 app 进程里执行（见 CCLiveActivityAttributes.swift 文件头）。
/// - 过期（15 分钟没更新 ⇒ app 多半不在了）：睡着的脸、灰点、「已断开」，**不画按钮、不画进度条**。
/// - 高度：锁屏卡片**不能超过 160pt**（Apple HIG：超了会被截）。预算见 `CCActivityLockScreen.body`。
struct CCLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CCLiveActivityAttributes.self) { context in
            CCActivityLockScreen(state: context.state, stale: context.isStale)
                // 脸的设计是黑底白眼（AgentTouch 原样），锁屏不管系统深浅色都给一块深底。
                .activityBackgroundTint(Color.black.opacity(0.78))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let shown = context.isStale ? context.state.staleVersion : context.state
            let stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CCActivityFace(state: shown, side: 44)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // 自己的点在上，其他房间只画点（展开态横向放不下名字）。
                    VStack(alignment: .trailing, spacing: 4) {
                        CCActivityDot(dot: shown.dot, size: 8)
                        CCActivityPeerDots(peers: shown.peers)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(shown.room)
                            .font(.headline)
                            .lineLimit(1)
                        Text(shown.statusLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // 展开态同样有 160pt 上限：中间名字＋状态 ≈64、这里 进度 16 ＋ 6 ＋ 按钮 44 ＝ 66。
                    VStack(spacing: 6) {
                        if !stale && shown.playDisplay != .hidden { CCActivityProgress(state: shown) }
                        if !stale { CCActivityActionRow(state: shown) }
                    }
                }
            } compactLeading: {
                CCActivityFace(state: shown, side: 22)
            } compactTrailing: {
                CCActivityDot(dot: shown.dot, size: 6)
            } minimal: {
                CCActivityFace(state: shown, side: 20)
            }
            .keylineTint(CCIdentityColor.color(for: shown.room))
        }
    }
}

// MARK: - 锁屏卡片

struct CCActivityLockScreen: View {
    let state: CCLiveActivityState
    let stale: Bool

    private var shown: CCLiveActivityState { stale ? state.staleVersion : state }

    // 布局：上面「脸 ＋ 名字状态」，下面**两颗占满宽度的大按钮**。
    // Chris 2026-10-05：「主要操作就是重播、暂停／恢复这两件事，做成大按钮。」
    // 锁屏上按的是一只拇指，小胶囊按钮（原来 caption 字、5pt 内边距）很难按准。
    //
    // ## 高度预算（≤ 160pt，Apple HIG：锁屏实时活动超过 160pt 会被截）
    //
    // 原来约 180pt+（脸 52、按钮 48、内边距 14×2、行距 10、底下还单独一行其他房间）。现在：
    //
    //   上下内边距               10 ＋ 10                         ＝  20
    //   第一行   max(脸 44, 名字行 22 ＋ 间距 2 ＋ 状态两行 2×20)  ＝  64
    //   行距 6 ＋ 进度条（caption 一行）16                        ＝  22   （只在有语音时）
    //   行距 6 ＋ 按钮 44                                          ＝  50
    //   ─────────────────────────────────────────────────────────
    //   合计（最坏：两行状态 ＋ 进度 ＋ 按钮）                     ＝ 156 ≤ 160
    //
    // 其他房间的小圆点挪进名字那一行右侧，不再单独占一行（省下 ≈ 22）。
    // 字号按系统默认（Large）算；用户把动态字体调大时系统会自己缩实时活动里的字，
    // 但调到辅助功能那几档时这份预算不保证 —— 那时状态行会先被截成一行。
    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                CCActivityFace(state: shown, side: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(shown.room)
                            .font(.headline)
                            .lineLimit(1)
                            .layoutPriority(1)
                        CCActivityDot(dot: shown.dot, size: 8)
                        Spacer(minLength: 4)
                        // 放不下名字就只画点，再放不下就不画 —— 绝不把自己的名字挤没。
                        ViewThatFits(in: .horizontal) {
                            CCActivityPeers(peers: shown.peers)
                            CCActivityPeerDots(peers: shown.peers)
                            EmptyView()
                        }
                    }
                    Text(shown.statusLine)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }
            }
            // 语音进度：有正在播 / 能重播的那段才出现（样子照 app 里的 CCPlaybackBar）。
            if !stale && shown.playDisplay != .hidden { CCActivityProgress(state: shown) }
            if !stale { CCActivityActionRow(state: shown) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // 读屏：一句话念完（脸是纯图形，不能只靠形状传信息 —— 跟 app 里活脸同一条）。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(shown.room)，\(shown.faceMood.spoken)，\(shown.statusLine)，\(shown.dot.spoken)"))
    }
}

// MARK: - 零件

/// 一帧静态的活脸：按心情选定姿态，`reduceMotion: true` 保证跟时间无关
/// （`CCFaceMotion` 的测试钉着「减弱动态时画面不随时间变」）。
struct CCActivityFace: View {
    let state: CCLiveActivityState
    let side: CGFloat

    var body: some View {
        CCFaceGlyph(
            scene: CCFaceMotion.scene(.init(
                mood: state.faceMood, skin: state.faceSkin, t: 0, since: 0,
                seed: CCFaceMotion.seed(for: state.room),
                // 小于 80pt 不画问号、打字点这些小道具（跟 app 里方块上的小脸一个规矩）。
                compact: side < 80, reduceMotion: true,
                typingDots: CCFaceMood.typingDots(runningSubtasks: state.subtasks))),
            tint: CCIdentityColor.color(for: state.room),
            side: side)
            .accessibilityHidden(true)
    }
}

/// 在线小圆点。颜色跟 app 里同一份（`CCPresenceDot.signalHex`）。
struct CCActivityDot: View {
    let dot: CCPresenceDot
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color(hex: dot.signalHex))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// 计时已整个拿掉。Chris 2026-10-05：先是「没看出来计时记的是什么时间」，
// 改成只在查东西时显示「已查 0:12」之后，仍然「这个不要」。
// ⇒ 卡片上不放任何计时；`timerStart` 字段留在状态里没删（app 端还在写），
//   以后真要恢复不用改数据结构。

/// 暂停 / 继续 ＋ 重播。
///
/// ⚠️ 图标按卡片上那份状态画，**可能差几秒**：有卡时 app 替卡片挂着进度轮询，但播完后
/// 4 秒才拉一次（`CCPlaybackRemote.acquirePolling`），卡片也有 1 秒节流。
/// 不要紧 —— 那颗键做的是「先问服务端、再决定停还是继续还是重播」
/// （`CCPlaybackRemote.smartToggle`），动作一定对，图标按完就会跟上。
struct CCActivityControls: View {
    let state: CCLiveActivityState

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: CCLiveActivityToggleIntent(room: state.room)) {
                big(state.isPlaying ? "暂停" : "继续",
                    systemImage: state.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            Button(intent: CCLiveActivityReplayIntent(room: state.room)) {
                big("重播", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
        }
    }

    private func big(_ title: String, systemImage: String) -> some View {
        CCActivityBigLabel(title: title, systemImage: systemImage)
    }
}

/// 大按钮的样子：两颗平分整行，**高 44pt**（Apple 的最小可点区域，正好卡住 160pt 预算；
/// 原来 48pt 时整张卡超高被截）。字从 title3 降到 headline，44pt 里放得下图标 ＋ 字。
struct CCActivityBigLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.18)))
            .contentShape(Rectangle())
    }
}

/// 卡片最下面那一行：平时是暂停 / 重播，**bot 在等你回话时换成快捷回复**。
/// 两种同高（44pt），换来换去卡片不跳。
struct CCActivityActionRow: View {
    let state: CCLiveActivityState

    var body: some View {
        if state.quickReplyShown {
            CCActivityQuickReplies(state: state)
        } else {
            CCActivityControls(state: state)
        }
    }
}

/// 快捷回复：「没问题，请继续」「按照你的想法来」。点下去在 app 进程里走 app 的文字通道
/// （`session.send(text:)`，跟聊天框同一条）发给 bot 本体，**不经过语音助手**
/// （见 `CCLiveActivityQuickReplyIntent`）。发出的永远是完整原句；按钮放不下时只是**显示**简写。
/// 发出后状态行显示「已回复：<完整原句>」3 秒，这两颗按钮在那 3 秒里先收起来（防连按）。
struct CCActivityQuickReplies: View {
    let state: CCLiveActivityState

    var body: some View {
        HStack(spacing: 10) {
            ForEach(CCLiveActivityState.quickReplies, id: \.self) { r in
                Button(intent: CCLiveActivityQuickReplyIntent(room: state.room, text: r.text)) {
                    // 先试整句，放不下再用简写 —— 两种同高，换了卡片不跳。
                    ViewThatFits(in: .horizontal) {
                        CCActivityBigLabel(title: r.text, systemImage: Self.icon(for: r))
                        CCActivityBigLabel(title: r.short, systemImage: Self.icon(for: r))
                    }
                }
                .buttonStyle(.plain)
                // 读屏念完整原句（简写只是视觉上的退让）。
                .accessibilityLabel(Text(verbatim: r.text))
                .accessibilityHint(Text(verbatim: state.waitText.map { "回复 \(state.room)：\($0)" } ?? ""))
            }
        }
    }

    /// 第一颗「没问题，请继续」打勾，第二颗「按照你的想法来」是交给它定（`hand.thumbsup`）。
    /// 按位置不按字面，改了措辞图标不会错位。
    static func icon(for r: CCLiveActivityState.QuickReply) -> String {
        r == CCLiveActivityState.quickReplies.first ? "checkmark" : "hand.thumbsup"
    }
}

/// 语音播放进度：左边已播、中间进度条、右边总长 —— 照 app 里的 `CCPlaybackBar`。
///
/// **在播时全靠系统计时视图自己走**（`Text(timerInterval:)` ＋ `ProgressView(timerInterval:)`），
/// app 只在开始 / 暂停 / 继续 / 换段 / 总长变了 / 偏差 > 2 秒时推一次
/// （判定在 `CCLiveActivityPolicy.playMark`，离线测过）。四种样子见 `CCLiveActivityState.PlayDisplay`。
struct CCActivityProgress: View {
    let state: CCLiveActivityState

    /// 两端数字的宽度。系统计时文本会撑满能拿到的宽度，**不给定宽它会把进度条挤没**。
    private let side: CGFloat = 46
    /// 进度蓝：跟 app 播放条一样用系统蓝；底色用 ProgressView 自带的灰轨道。
    private let blue = Color.blue

    var body: some View {
        Group {
            switch state.playDisplay {
            case .hidden:
                EmptyView()
            case let .running(range):
                HStack(spacing: 8) {
                    Text(timerInterval: range, countsDown: false)
                        .frame(width: side, alignment: .leading)
                    // label / currentValueLabel 都给空：默认那份会在条下面再画一个计时，跟左边重复。
                    ProgressView(timerInterval: range, countsDown: false,
                                 label: { EmptyView() }, currentValueLabel: { EmptyView() })
                        .progressViewStyle(.linear)
                        .tint(blue)
                    Text(verbatim: CCLiveActivityState.clock(range.upperBound.timeIntervalSince(range.lowerBound)))
                        .frame(width: side, alignment: .trailing)
                }
            case let .growing(since):
                HStack(spacing: 8) {
                    Text(timerInterval: since...since.addingTimeInterval(12 * 3600), countsDown: false)
                        .frame(width: side, alignment: .leading)
                    // 总长未知不画条 —— 拿猜的分母画会显示成「快播完了」（CCPlaybackBar 同一条）。
                    Text(verbatim: "生成中")
                    Spacer(minLength: 0)
                }
            case let .still(played, total):
                HStack(spacing: 8) {
                    Text(verbatim: CCLiveActivityState.clock(played))
                        .frame(width: side, alignment: .leading)
                    if let total {
                        ProgressView(value: CCLiveActivityState.fraction(played: played, total: total))
                            .progressViewStyle(.linear)
                            .tint(blue)
                        Text(verbatim: CCLiveActivityState.clock(total))
                            .frame(width: side, alignment: .trailing)
                    } else {
                        Text(verbatim: "生成中")
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.7))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    private var spoken: String {
        switch state.playDisplay {
        case .hidden: return ""
        case let .running(r): return "正在播放，共 \(CCLiveActivityState.clock(r.upperBound.timeIntervalSince(r.lowerBound)))"
        case .growing: return "正在播放，还在生成"
        case let .still(p, t):
            return "已播 \(CCLiveActivityState.clock(p))" + (t.map { "，共 \(CCLiveActivityState.clock($0))" } ?? "，还在生成")
        }
    }
}

/// 其他房间只画小圆点（地方不够放名字时：灵动岛展开态、名字行挤不下时）。
struct CCActivityPeerDots: View {
    let peers: [CCLiveActivityState.Peer]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(peers, id: \.name) { p in
                CCActivityDot(dot: CCPresenceDot(rawValue: p.dot) ?? .off, size: 6)
            }
        }
    }
}

/// 其他房间的名字 ＋ 小圆点。
struct CCActivityPeers: View {
    let peers: [CCLiveActivityState.Peer]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(peers, id: \.name) { p in
                HStack(spacing: 3) {
                    Text(p.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .fixedSize()
                    CCActivityDot(dot: CCPresenceDot(rawValue: p.dot) ?? .off, size: 6)
                }
            }
        }
        .foregroundStyle(.white.opacity(0.8))
    }
}
