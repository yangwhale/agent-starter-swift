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
                // 右上角不放东西：岛的圆角很大，原来那列小圆点（自己 ＋ 其他房间）
                // 被切掉一半（Chris 2026-10-06 截图）。在线点挪到名字前面，其他房间只在锁屏卡片上显示。
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            CCActivityDot(dot: shown.dot, size: 8)
                            Text(shown.room)
                                .font(.headline)
                                .lineLimit(1)
                        }
                        Text(shown.statusLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            // 等你回话时下面多一行小播放条，状态让成一行（预算见锁屏卡片那段）。
                            .lineLimit(shown.quickReplyShown ? 1 : 2)
                            .multilineTextAlignment(.center)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // 展开态同样有 160pt 上限：中间名字＋状态 ≈64、这里 进度 16 ＋ 6 ＋ 按钮 44 ＝ 66。
                    // 岛的下沿两角是大圆弧：按钮贴边会被切掉角（同一张截图），
                    // 所以左右各缩 12pt、按钮矮到 38pt，给下沿留出圆弧的位置。
                    VStack(spacing: 6) {
                        if !stale { CCActivityBottom(state: shown) }
                    }
                    .environment(\.ccActivityButtonHeight, 38)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
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
    // **等你回话时**（2026-10-06）下面换成「小播放条 ＋ 一行 2~4 颗回答」，见 `CCActivityBottom`：
    //
    //   上下内边距                                                ＝  20
    //   第一行   状态让成一行：max(脸 44, 22 ＋ 2 ＋ 20)          ＝  44
    //   行距 6 ＋ 小播放条（暂停 ⟷ 进度 ⟷ 重播，图标键 36）       ＝  42
    //   行距 6 ＋ 回答 44                                          ＝  50
    //   ─────────────────────────────────────────────────────────
    //   合计                                                       ＝ 156 ≤ 160
    //
    // 为什么停在 156 不顶到 160：上面的数是按字号估的不是量的，**156 是真机上验证过不被截的**
    // （平时那套布局就是 156），160 没验证过。多出来的 8 全给了小播放条那两颗键 ——
    // 没听清时要点重播，它是这一屏里最该好按的东西（Chris 2026-10-06：「这个高度极其稀缺，要用满」）。
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
                        // 等你回话时让成一行，腾出地方给小播放条（预算见上）。
                        .lineLimit(shown.quickReplyShown ? 1 : 2)
                }
            }
            if !stale { CCActivityBottom(state: shown) }
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
    /// nil ⇒ 只有字（一行三四颗回答时，宽度留给字）。
    let systemImage: String?
    @Environment(\.ccActivityButtonHeight) private var height

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(systemImage == nil ? 0.75 : 1)
            .padding(.horizontal, systemImage == nil ? 4 : 0)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.18)))
            .contentShape(Rectangle())
    }
}

/// 卡片下半截：平时是「进度条 ＋ 暂停 / 重播两颗大按钮」；**bot 在等你回话时**是
/// 「小播放条 ＋ 一行 2~4 颗回答」。
///
/// Chris 2026-10-06：「等你选的时候，重播和暂停还得要着，哪怕扁一点 —— 我要重播
/// 通常就是没听清，没听清让我在四个选项里选，我也选不上来，这时候得能点重播。」
/// 所以等你时不把播放控制换掉，而是**缩成进度条两头的两颗图标键**，跟回答共存。
struct CCActivityBottom: View {
    let state: CCLiveActivityState

    var body: some View {
        if state.quickReplyShown {
            VStack(spacing: 6) {
                // 没有可播 / 可重播的语音就不画这条（按了也没东西放）。
                if state.playDisplay != .hidden || state.canReplay { CCActivityMiniPlayRow(state: state) }
                CCActivityQuickReplies(state: state)
            }
        } else {
            VStack(spacing: 6) {
                // 语音进度：有正在播 / 能重播的那段才出现（样子照 app 里的 CCPlaybackBar）。
                if state.playDisplay != .hidden { CCActivityProgress(state: state) }
                CCActivityControls(state: state)
            }
        }
    }
}

/// 等你回话时的小播放条：左暂停 / 继续、中间进度、右重播。两颗键是 36pt 的圆形图标键 ——
/// 比大按钮扁，但仍是独立可点的键（同一个 intent，动作跟大按钮完全一样）。
struct CCActivityMiniPlayRow: View {
    let state: CCLiveActivityState

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: CCLiveActivityToggleIntent(room: state.room)) {
                icon(state.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: state.isPlaying ? "暂停" : "继续"))
            if state.playDisplay != .hidden {
                CCActivityProgress(state: state)
            } else {
                Spacer(minLength: 0)
            }
            Button(intent: CCLiveActivityReplayIntent(room: state.room)) {
                icon("arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "重播"))
        }
        .frame(height: 36)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .bold))
            .frame(width: 36, height: 36)
            .background(Circle().fill(.white.opacity(0.18)))
            .contentShape(Circle())
    }
}

/// 快捷回复：「没问题，请继续」「按照你的想法来」。点下去在 app 进程里走 app 的文字通道
/// （`session.send(text:)`，跟聊天框同一条）发给 bot 本体，**不经过语音助手**
/// （见 `CCLiveActivityQuickReplyIntent`）。发出的永远是完整原句；按钮放不下时只是**显示**简写。
/// 发出后状态行显示「已回复：<完整原句>」3 秒，这两颗按钮在那 3 秒里先收起来（防连按）。
struct CCActivityQuickReplies: View {
    let state: CCLiveActivityState

    var body: some View {
        // bot 带了推荐答案就是它的，没带就是固定那两句（跟 app 主界面同一个函数）。
        let choices = CCQuickReply.choices(options: state.replyOptions, labels: state.replyLabels)
        // 2~4 颗都排**一行**（Chris 2026-10-06）。超过两颗时去掉图标、缩小间距，把宽度留给字。
        let roomy = choices.count <= 2
        HStack(spacing: roomy ? 10 : 6) {
            ForEach(choices, id: \.self) { r in
                Button(intent: CCLiveActivityQuickReplyIntent(room: state.room, text: r.text)) {
                    // 先试整句，放不下再用简写 —— 两种同高，换了卡片不跳。
                    ViewThatFits(in: .horizontal) {
                        CCActivityBigLabel(title: r.text, systemImage: roomy ? r.symbol : nil)
                        CCActivityBigLabel(title: r.short, systemImage: roomy ? r.symbol : nil)
                    }
                }
                .buttonStyle(.plain)
                // 读屏念完整原句（简写只是视觉上的退让）。
                .accessibilityLabel(Text(verbatim: r.text))
                .accessibilityHint(Text(verbatim: state.waitText.map { "回复 \(state.room)：\($0)" } ?? ""))
            }
        }
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

// 其他房间：**点一下就切过去**（Chris 2026-10-06）。不另加按钮 —— 卡片高度预算已经用满，
// 名字行右边本来就画着它们，让它们可点就行。每个做成一颗淡底小胶囊，看得出是能按的。

/// 其他房间只画小圆点（名字行挤不下名字时）。点同样能切。
struct CCActivityPeerDots: View {
    let peers: [CCLiveActivityState.Peer]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(peers, id: \.name) { p in
                Button(intent: CCLiveActivitySwitchIntent(room: p.name)) {
                    CCActivityDot(dot: CCPresenceDot(rawValue: p.dot) ?? .off, size: 6)
                        .padding(6)
                        .background(Capsule().fill(.white.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "切到 \(p.name)"))
            }
        }
    }
}

/// 其他房间的名字 ＋ 小圆点，点一下切过去。
struct CCActivityPeers: View {
    let peers: [CCLiveActivityState.Peer]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(peers, id: \.name) { p in
                Button(intent: CCLiveActivitySwitchIntent(room: p.name)) {
                    HStack(spacing: 3) {
                        Text(p.name)
                            .font(.caption)
                            .lineLimit(1)
                            .fixedSize()
                        CCActivityDot(dot: CCPresenceDot(rawValue: p.dot) ?? .off, size: 6)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "切到 \(p.name)"))
            }
        }
        .foregroundStyle(.white.opacity(0.9))
    }
}

/// 大按钮高度：锁屏卡片 44pt，灵动岛展开态 38pt（岛下沿是大圆弧，要让出位置）。
private struct CCActivityButtonHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 44
}

extension EnvironmentValues {
    var ccActivityButtonHeight: CGFloat {
        get { self[CCActivityButtonHeightKey.self] }
        set { self[CCActivityButtonHeightKey.self] = newValue }
    }
}
