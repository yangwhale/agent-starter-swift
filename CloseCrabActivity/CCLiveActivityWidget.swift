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
///  ◡ ◡   bunny ●                       12:48
///        跑 Q10 验收（3 个子任务）
///        [⏸ 暂停] [↺ 重播]      jarvis ● tommy ●
/// ```
///
/// - 脸：按心情选定的**一帧**（实时活动里不能跑连续动画）。同一套形状和身份色金属。
/// - 计时：系统的计时文本，自己会走，不靠每秒推更新。
/// - 按钮：**两种音频模式都一直显示**（Chris 2026-10-05 后来简化的：不再按「系统播放控件」
///   开关藏起来）。点下去在 app 进程里执行（见 CCLiveActivityAttributes.swift 文件头）。
/// - 过期（15 分钟没更新 ⇒ app 多半不在了）：睡着的脸、灰点、「已断开」，**不画按钮、不走计时**。
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
                    CCActivityFace(state: shown, side: 52)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        if !stale { CCActivityTimer(state: shown, font: .title3) }
                        CCActivityDot(dot: shown.dot, size: 8)
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
                    VStack(spacing: 8) {
                        if !stale { CCActivityControls(state: shown) }
                        CCActivityPeers(peers: shown.peers)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } compactLeading: {
                CCActivityFace(state: shown, side: 22)
            } compactTrailing: {
                HStack(spacing: 4) {
                    CCActivityDot(dot: shown.dot, size: 6)
                    if !stale {
                        CCActivityTimer(state: shown, font: .caption2)
                            .frame(maxWidth: 44)
                    }
                }
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

    // 布局：上面「脸 ＋ 名字状态 ＋ 计时」，下面**两颗占满宽度的大按钮**。
    // Chris 2026-10-05：「主要操作就是重播、暂停／恢复这两件事，做成大按钮。」
    // 锁屏上按的是一只拇指，小胶囊按钮（原来 caption 字、5pt 内边距）很难按准。
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                CCActivityFace(state: shown, side: 52)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(shown.room)
                            .font(.headline)
                            .lineLimit(1)
                        CCActivityDot(dot: shown.dot, size: 8)
                        Spacer(minLength: 4)
                        if !stale { CCActivityTimer(state: shown, font: .headline) }
                    }
                    Text(shown.statusLine)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }
            }
            if !stale { CCActivityControls(state: shown) }
            if !shown.peers.isEmpty {
                CCActivityPeers(peers: shown.peers)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
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

/// 系统计时文本：从 `timerStart` 往上数，自己走。上限给 12 小时（单卡最长 8 小时，用不到）。
struct CCActivityTimer: View {
    let state: CCLiveActivityState
    let font: Font

    var body: some View {
        Text(timerInterval: state.timerStart...state.timerStart.addingTimeInterval(12 * 3600),
             countsDown: false)
            .font(font.monospacedDigit())
            .multilineTextAlignment(.trailing)
    }
}

/// 暂停 / 继续 ＋ 重播。
///
/// ⚠️ 图标按卡片上那份状态画，**可能是旧的**：锁屏时 app 不轮询播放进度（省电那轮定的）。
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

    /// 大按钮：两颗平分整行，高 48pt（远大于 44pt 的最小可点区域），图标 ＋ 字。
    private func big(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.18)))
            .contentShape(Rectangle())
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
                    CCActivityDot(dot: CCPresenceDot(rawValue: p.dot) ?? .off, size: 6)
                }
            }
        }
        .foregroundStyle(.white.opacity(0.8))
    }
}
