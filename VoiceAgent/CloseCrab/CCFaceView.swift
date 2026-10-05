import SwiftUI

// 眼睛、眼皮、道具的轮廓与动作移植自 AgentTouch (https://github.com/wentong2022-arch/agenttouch)
// firmware/src/face.cpp、grokface.cpp（几何和规则在 CCFaceMotion.swift，这里只按清单画）。
// Required Notice: Copyright (c) 2026 yuwentong (https://github.com/wentong2022-arch/agenttouch)
// 按 PolyForm Noncommercial License 1.0.0 授权，仅限非商业用途；
// 全文见 THIRD_PARTY_LICENSES/AgentTouch-PolyForm-Noncommercial-1.0.0.txt。

/// bot 的「活脸」—— 一个房间一张，主页面中间（大）、顶部方块和侧栏头像（小）共用。
///
/// ## 分工
///
/// - 哪张脸：`CCFaceMood`（纯函数，离线测过）
/// - 这一帧长什么样：`CCFaceMotion.scene`（AgentTouch 的移植，纯函数，离线测过）
/// - 材质：`CCMetal` ＋ `ccMetalGlow` —— **跟声音柱子同一份**（Chris 的要求）
/// - 这里：每帧取信号 → 算清单 → 画成遮罩 → 金属透过遮罩露出来
/// - 画成遮罩那一步（`CCFaceGlyph` / `CCFacePainter`）在 `CCFaceGlyph.swift` ——
///   锁屏实时活动的扩展也要画这张脸，而扩展不链 LiveKit，所以跟这个文件拆开了
///
/// ## 没有自己的底
///
/// 脸直接落在宿主原有的容器上（主页面那个大框、方块的底板、侧栏头像的底），
/// 跟原来那排柱子一样。所以眼皮**只能用裁剪**做（在遮罩上挖掉），不能画背景色去盖。
/// 身份色描边也不要 —— 方块本来就有自己的外圈。
///
/// ## 省电（九月那轮耗电改造不能退回去）
///
/// - 看不见就停：读 `ccRendering`，为 false 时 `TimelineView` 暂停
/// - 帧率：小脸 15、大脸 30
/// - 减弱动态效果：画面本来就不随时间动（`CCFaceMotion` 保证、测试钉着），
///   帧率降到 2 —— 只为「刚干完」那 3 秒窗口到点能切回空闲
struct CCSlotFace: View {
    let slot: CCRoomSlot
    /// 在线小圆点（`CCRooms.presence(for:)`）。由调用方传 —— 槽位自己不知道「用户想不想连」。
    let presence: CCPresenceDot
    let skin: CCFaceSkin
    /// 边长（pt）。决定细节多少：小于 80 不画问号、打字点这些小道具。
    let side: CGFloat

    @Environment(\.ccRendering) private var rendering
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = CCFaceClock()

    private var compact: Bool { side < 80 }

    private var interval: Double {
        if reduceMotion { return 0.5 }
        return compact ? 1.0 / 15 : 1.0 / 30
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: !rendering)) { ctx in
            CCFaceGlyph(scene: scene(at: ctx.date),
                        tint: CCIdentityColor.color(for: slot.name),
                        side: side)
        }
        .frame(width: side, height: side)
        // 小脸挂在方块 / 侧栏行里，那两处已经合成了一句完整的读屏文字 —— 不重复念。
        .accessibilityHidden(compact)
        .accessibilityLabel(Text(verbatim: "\(slot.name)\(mood(at: .now).spoken)"))
    }

    private func mood(at date: Date) -> CCFaceMood {
        let snap = slot.botStatus.snap
        return CCFaceMood.derive(
            presence: presence,
            botPresent: slot.botPresent,
            wait: snap?.wait ?? "",
            on: snap?.on ?? false,
            holding: slot.micPolicy.isHolding,
            speaking: slot.isSpeaking,
            muted: slot.isMuted,
            finishedAt: slot.botStatus.finishedAt,
            speechEndedAt: slot.speechEndedAt,
            now: date
        )
    }

    private func scene(at date: Date) -> CCFaceMotion.Scene {
        let m = mood(at: date)
        let t = date.timeIntervalSinceReferenceDate
        let seed = CCFaceMotion.seed(for: slot.name)
        clock.enter(m, skin: skin, t: t, seed: seed)
        return CCFaceMotion.scene(.init(
            mood: m, skin: skin, t: t, since: clock.since, seed: seed,
            compact: compact, reduceMotion: reduceMotion,
            typingDots: CCFaceMood.typingDots(runningSubtasks: slot.botStatus.snap?.subs.run ?? 0),
            grokFrom: clock.grokFrom))
    }
}

/// 图标选择器里那一排皮肤的静态样子：睁眼（「在听」那张，最能看出眼型）＋ 头饰。
/// 不挂定时器 —— 选择器里六个同时在场，没必要让它们都动。
struct CCFacePreview: View {
    let skin: CCFaceSkin
    let tint: Color
    let side: CGFloat

    var body: some View {
        CCFaceGlyph(
            scene: CCFaceMotion.scene(.init(mood: .listening, skin: skin, t: 0, since: 0, seed: 1,
                                            compact: true, reduceMotion: true)),
            tint: tint, side: side)
            .accessibilityHidden(true)
    }
}

/// 记「进入当前心情的时刻」。眨眼调度、换脸、出汗都从这个时刻算起（见 `CCFaceMotion`）。
///
/// **普通 class，不是 @Observable** —— 它在 body 里被改写，要是可观察的，
/// 改写就会让 body 失效、再算、再改写……跟 `AgentView` 里那个 `epoch` 同一类闭环。
/// 这里改的东西没有任何视图在订阅，所以不会闭合。
final class CCFaceClock {
    private var mood: CCFaceMood?
    private var skin: CCFaceSkin?
    private(set) var since: Double = 0
    /// grok：进入当前心情那一刻正显示的表情，换心情时从它变形过来。
    private(set) var grokFrom: Int?

    /// 每帧调；心情没变就什么都不做（幂等 —— body 可能被多算几遍）。
    func enter(_ m: CCFaceMood, skin s: CCFaceSkin, t: Double, seed: UInt64) {
        guard m != mood || s != skin else { return }
        if let old = mood, s == .grok, skin == .grok {
            grokFrom = CCFaceMotion.grokShowing(mood: old, since: since, t: t, seed: seed, grokFrom: grokFrom)
        } else {
            grokFrom = nil
        }
        mood = m
        skin = s
        since = t
    }
}
