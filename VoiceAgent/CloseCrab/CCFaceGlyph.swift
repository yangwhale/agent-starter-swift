import SwiftUI

// 绘制方式移植自 AgentTouch (https://github.com/wentong2022-arch/agenttouch)
// firmware/src/face.cpp、grokface.cpp（几何和规则在 CCFaceMotion.swift，这里只按清单画）。
// Required Notice: Copyright (c) 2026 yuwentong (https://github.com/wentong2022-arch/agenttouch)
// 按 PolyForm Noncommercial License 1.0.0 授权，仅限非商业用途；
// 全文见 THIRD_PARTY_LICENSES/AgentTouch-PolyForm-Noncommercial-1.0.0.txt。

// ## 为什么从 CCFaceView.swift 里拆出来（2026-10-05，实时活动第一步）
//
// 锁屏 / 灵动岛实时活动在另一个 target（`CloseCrabActivity` 扩展）里画同一张脸。
// 扩展**不链 LiveKit**，而 `CCFaceView.swift` 里的 `CCSlotFace` 读的是 `CCRoomSlot`
// （LiveKit 的 Session / Room）——整文件编进扩展就编不过。
// 所以把「只吃一份绘制清单、不认识房间」的两样搬到这里：
//
// - `CCFaceGlyph`：金属透过脸形遮罩露出来＋柱子那三道阴影
// - `CCFacePainter`：清单 → 遮罩
//
// 这个文件**只依赖 SwiftUI ＋ CCFaceMotion ＋ CCMetalGlow**，两个 target 都编它
// （扩展那边靠 pbxproj 里 "Exceptions for "VoiceAgent" folder in "CloseCrabActivity" target"
// 那条共享）。**往这里加东西前先确认它不碰 LiveKit / CCRooms / CCStore** ——
// 碰了 app 照样编得过，坏的是扩展，而扩展只有 tommy 在 Mac 上编得到。

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
