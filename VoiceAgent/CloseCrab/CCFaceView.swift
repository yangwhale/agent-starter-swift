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

/// 一帧：金属透过脸形遮罩露出来，再套柱子那三道阴影。
struct CCFaceGlyph: View {
    let scene: CCFaceMotion.Scene
    let tint: Color
    let side: CGFloat

    var body: some View {
        // 先取出来再进闭包：Canvas 的绘制闭包在不同 SDK 上的隔离标注不一定一样，
        // 只捕获 Sendable 的值（清单是纯数据）最稳。
        let prims = scene.prims
        CCMetal(tint: tint)
            .mask {
                Canvas { ctx, size in
                    CCFacePainter.paint(&ctx, size: size, prims: prims)
                }
            }
            .frame(width: side, height: side)
            .ccMetalGlow(tint: tint, glow: CCMetalGlowSpec.faceGlow(side: Double(side)))
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

/// 绘制清单 → 遮罩。坐标从原屏 480×480 等比缩放到视图里。
///
/// `nonisolated`：Canvas 的绘制闭包在新 SDK 上可能不在 MainActor 上跑，
/// 这里只碰 `GraphicsContext` / `Path` / `Color` 这些值类型，从哪个上下文调都安全。
nonisolated enum CCFacePainter {
    static func paint(_ ctx: inout GraphicsContext, size: CGSize, prims: [CCFacePrim]) {
        let side = min(size.width, size.height)
        let s = side / 480
        let tf = CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                   tx: (size.width - side) / 2, ty: (size.height - side) / 2)
        // 独立图层：下面的「挖掉」（destinationOut）只作用在这张脸自己画的东西上。
        ctx.drawLayer { layer in
            for p in prims {
                let (path, ink, stroked) = shape(p)
                let a = CCFaceMask.alpha(ink)
                let pathT = path.applying(tf)
                if CCFaceMask.replaces(ink) {
                    // 改写成不透明度 a：底下（白眼 / 白耳朵）是满的，destinationOut 掉 (1 − a) 就剩 a。
                    // 切口 a = 0 ＝ 整块挖掉 —— 这就是「眼皮用裁剪实现」。
                    layer.blendMode = .destinationOut
                    layer.fill(pathT, with: .color(Color.white.opacity(1 - a)))
                    layer.blendMode = .normal
                } else if stroked {
                    // 原固件是 1 px 细线（猫胡须）；缩小之后至少留 0.6 pt，不然在方块上直接没了。
                    layer.stroke(pathT, with: .color(Color.white.opacity(a)), lineWidth: max(0.6, 1.5 * s))
                } else {
                    layer.fill(pathT, with: .color(Color.white.opacity(a)), style: FillStyle(eoFill: true))
                }
            }
        }
    }

    /// 一笔 → 路径（480 坐标）。约定跟 Arduino_GFX 一样：y 朝下，角度 0 在三点钟。
    static func shape(_ p: CCFacePrim) -> (Path, CCFaceInk, Bool) {
        switch p {
        case let .roundRect(x, y, w, h, r, ink):
            let rr = max(0, min(r, w / 2, h / 2))
            return (Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: rr, style: .circular), ink, false)
        case let .rect(x, y, w, h, ink):
            return (Path(CGRect(x: x, y: y, width: w, height: h)), ink, false)
        case let .triangle(a, b, c, ink):
            var path = Path()
            path.move(to: CGPoint(x: a.x, y: a.y))
            path.addLine(to: CGPoint(x: b.x, y: b.y))
            path.addLine(to: CGPoint(x: c.x, y: c.y))
            path.closeSubpath()
            return (path, ink, false)
        case let .circle(cx, cy, r, ink):
            return (Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)), ink, false)
        case let .arc(cx, cy, r1, r2, from, to, ink):
            // 圆环的一段：外弧正着走、内弧倒着回来。逐点采样，不用 addArc ——
            // addArc 的 clockwise 在 y 朝下的坐标里是反的，写错了弯眼就倒过来成了「∪」。
            let ro = max(r1, r2), ri = min(r1, r2)
            let n = 32
            var path = Path()
            for k in 0...n {
                let a = (from + (to - from) * Double(k) / Double(n)) * .pi / 180
                let pt = CGPoint(x: cx + ro * cos(a), y: cy + ro * sin(a))
                if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            for k in stride(from: n, through: 0, by: -1) {
                let a = (from + (to - from) * Double(k) / Double(n)) * .pi / 180
                path.addLine(to: CGPoint(x: cx + ri * cos(a), y: cy + ri * sin(a)))
            }
            path.closeSubpath()
            return (path, ink, false)
        case let .pill(cx, cy, len, thick, deg, ink):
            let base = Path(roundedRect: CGRect(x: -len / 2, y: -thick / 2, width: len, height: thick),
                            cornerRadius: thick / 2, style: .circular)
            let tf = CGAffineTransform(rotationAngle: deg * .pi / 180)
                .concatenating(CGAffineTransform(translationX: cx, y: cy))
            return (base.applying(tf), ink, false)
        case let .line(a, b, ink):
            var path = Path()
            path.move(to: CGPoint(x: a.x, y: a.y))
            path.addLine(to: CGPoint(x: b.x, y: b.y))
            return (path, ink, true)
        case let .polygon(pts, ink):
            var path = Path()
            if let f = pts.first {
                path.move(to: CGPoint(x: f.x, y: f.y))
                for q in pts.dropFirst() { path.addLine(to: CGPoint(x: q.x, y: q.y)) }
                path.closeSubpath()
            }
            return (path, ink, false)
        }
    }
}
