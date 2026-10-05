import Foundation

// 移植自 AgentTouch (https://github.com/wentong2022-arch/agenttouch)
// firmware/src/face.cpp、face.h、grokface.cpp、grokface.h、config.h。
// Required Notice: Copyright (c) 2026 yuwentong (https://github.com/wentong2022-arch/agenttouch)
// 按 PolyForm Noncommercial License 1.0.0 授权，仅限非商业用途；
// 全文见 THIRD_PARTY_LICENSES/AgentTouch-PolyForm-Noncommercial-1.0.0.txt。
//
// grok 皮肤的眼睛坐标来自 GrokBot（BSD-3-Clause，见 CCFaceGrokEyes.swift 文件头）。

/// bot「活脸」的动作与几何 —— **AgentTouch 那张脸的逐项移植**。只依赖 Foundation，离线可测。
///
/// Chris 2026-10-05：「五套皮肤的脸不要自己画，直接移植 AgentTouch 的设计 ——
/// 人家的脸有美术功底。」所以这里的每一个数（眼睛位置宽高圆角、眼皮切法、
/// 道具坐标、眨眼曲线和间隔表、扫视循环、呼吸、grok 的弹簧）
/// **都照原固件抄**，坐标保留原屏 480×480 —— 视图按边长等比缩放。
/// 改数之前先去原文件对一下，别凭感觉「调好看一点」。
///
/// ## 结构
///
/// 1. `CCFaceMood`（我们的）→ `CCFaceLook`（他们的十种视觉状态）
/// 2. 时间轴：眨眼调度、表情池换脸、grok 弹簧 —— 全是 **(时间, 种子, 进入该状态的时刻)
///    的纯函数**。原固件是一帧帧推进的状态机（`static` 变量记「下次眨眼在什么时候」），
///    这里改成从进入时刻起按同一张表重放：同样的输入永远同样的输出，
///    `TimelineView` 跳帧、暂停（看不见时）都不会让节奏错乱，测试也能复现。
/// 3. `scene(_:)` 出一份**绘制清单**（圆角矩形、三角、圆弧、多边形……，480 坐标），
///    视图只负责照单画。眼睛下沿固定这类约束在清单上就能断言，不用肉眼看。
///
/// ## 跟原固件刻意不同的地方（都写了为什么）
///
/// - 眨眼进行到一半时换了状态：原固件让那一眨做完，这里直接截断（≤0.32 秒的差别），
///   换来的是「不用记上一个状态的调度」。
/// - 「等你」状态 grok 的整脸上移 56 px 是为了给板子上的「批准」气泡让位，
///   我们没有那个气泡，所以不移。
/// - 原固件按声音方向转眼神（`lookX/lookY`，眼神追声），我们没有声源方向，恒为 0。
/// - 打字点原来固定 3 个；方案页要求「有子任务时更多」，所以个数可变，
///   排法沿用原来的 28 px 间距、220 ms 错相，以 240 为中线居中。
/// - 「在说话」原固件没有这个状态，借「被抚摸」那张脸（弯眼＋脸红＋轻晃）。
/// - 动作的随机数换成确定性的 splitmix64（原来是按开机时刻播种的 LCG）。
/// - **颜色不搬**：原固件是黑底上的白眼和几种道具色；我们没有底，材质用声音柱子那块
///   身份色金属（Chris 的决定），原来的颜色层次换成遮罩不透明度，见 `CCFaceMask`。

// MARK: - 皮肤

/// 活脸的皮肤。**每个房间各存一份**（`CCStore.faceSkin(room:)`），没存＝这个房间不用活脸。
///
/// 皮肤只改长相（眼型、头上的道具），不改表情规则 —— 原固件的原话：
/// 「same soul, different body」。rawValue 直接落盘，也是原固件 `faceSkinName` 的拼写，
/// **只能加不能改**。
nonisolated public enum CCFaceSkin: String, Sendable, Equatable, CaseIterable {
    /// 胶囊眼，什么都不加。
    case classic
    /// 胶囊眼＋三角猫耳＋每边三根胡须。
    case kitty
    /// 圆角方眼＋一个缓慢漂移、偶尔跳到对角的像素高光缺口。
    case robo
    /// 一只耳朵立着（粉色内耳）、一只折下来。
    case bunny
    /// 头顶一株两片叶的小芽。
    case sprout
    /// 纯黑脸＋两只 48 点多边形眼，表情之间弹簧变形（眼睛数据来自 GrokBot）。
    case grok

    public var title: String {
        switch self {
        case .classic: "经典"
        case .kitty: "小猫"
        case .robo: "机器人"
        case .bunny: "兔子"
        case .sprout: "小芽"
        case .grok: "Grok"
        }
    }

    /// 读盘用。空、未知值都返回 nil（＝不用活脸），**不退回 classic** ——
    /// 退回的话一个拼错的值会让房间凭空长出一张脸，而用户从没选过它。
    public static func parse(_ raw: String?) -> CCFaceSkin? {
        guard let raw else { return nil }
        return CCFaceSkin(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

// MARK: - 墨色（画进遮罩的不透明度）

/// 一笔是什么 —— **语义色板上的一格＋一个「压暗」系数**，不是具体的颜色。
///
/// ## 为什么不存颜色
///
/// Chris 2026-10-05：轮廓、动作照搬 AgentTouch，**材质和颜色用我们声音柱子那一套**
/// （`CCMetal` 身份色金属渐变 ＋ `ccMetalGlow` 三道阴影）。做法是把整张脸画成一张
/// **遮罩**，金属透过遮罩露出来 —— 所以清单里每一笔最后只剩一个数：在遮罩里有多不透明。
/// 原固件用颜色区分的那些层次（灰色的耷拉眼、暗一档的 z、粉色内耳、淡出的打字点），
/// 在这里变成不透明度的层次（`CCFaceMask.alpha`），同一块金属上的深浅。
nonisolated public enum CCFaceTone: Sendable, Equatable, CaseIterable {
    case eye, greyText, greyEye, greyDim, micBar, sweat, zDark, zLight, blush, pink, green
    case grokWhite, grokSleep, grokGone
    /// **眼皮 / 高光缺口 / o 形嘴的内圈** —— 原固件是拿背景色（纯黑）画一块盖上去。
    /// 我们的脸没有自己的底（直接落在宿主容器上），盖色块会露馅，
    /// 所以它不是一种颜色，是在遮罩上「挖掉」。
    case cut
}

/// 原固件里的颜色常量，名字沿用 face.cpp（`EYE`、`GREYEYE`……）。
/// `level` ＝ 原固件 `dim565(c, f)` 的 f：1 ＝ 原样，越小越淡。
nonisolated public struct CCFaceInk: Sendable, Equatable {
    public var tone: CCFaceTone
    public var level: Double

    public init(_ tone: CCFaceTone, level: Double = 1) { self.tone = tone; self.level = level }

    /// 原固件 `dim565`：往背景压。在遮罩里就是变淡（不透明度乘 f）。
    public func dim(_ f: Double) -> CCFaceInk {
        CCFaceInk(tone, level: level * min(1, max(0, f)))
    }

    public static let bg = CCFaceInk(.cut)
    public static let eye = CCFaceInk(.eye)
    public static let greyText = CCFaceInk(.greyText)
    public static let greyEye = CCFaceInk(.greyEye)
    public static let greyDim = CCFaceInk(.greyDim)
    public static let micBar = CCFaceInk(.micBar)
    public static let sweat = CCFaceInk(.sweat)
    public static let zDark = CCFaceInk(.zDark)
    public static let zLight = CCFaceInk(.zLight)
    /// 原固件 `BATTRED`（脸红用它压到 45%）。
    public static let battRed = CCFaceInk(.blush)
    public static let pink = CCFaceInk(.pink)
    public static let green = CCFaceInk(.green)
    public static let grokWhite = CCFaceInk(.grokWhite)
    public static let grokSleep = CCFaceInk(.grokSleep)
    public static let grokGone = CCFaceInk(.grokGone)
}

/// 墨色 → 遮罩。**纯函数，离线可测。**
///
/// 不透明度大致按原固件颜色的亮度排（黑底上越亮越显眼 ＝ 遮罩里越不透明）：
/// 白眼 1、浅灰的麦克风条 0.85、灰色胡须 / 睡着的 grok 0.55、断线的耷拉眼 0.5、
/// 更暗的 z 和断线短杠 0.3–0.45。具体值不是从 RGB 机械换算的 —— 金属渐变本身有
/// 亮带暗带，按亮度直译出来的 0.2 在金属上几乎看不见，所以都往上提了一档。
nonisolated public enum CCFaceMask {
    public static func alpha(_ ink: CCFaceInk) -> Double {
        let base: Double
        switch ink.tone {
        case .eye, .grokWhite, .green: base = 1
        case .micBar: base = 0.85
        case .sweat: base = 0.7
        case .greyText, .grokSleep: base = 0.55
        case .greyEye: base = 0.5
        case .grokGone: base = 0.45
        case .zLight: base = 0.45
        case .blush: base = 1          // 本身已经是 dim(0.45) 画的，见 petting
        case .pink: base = 0.45
        case .greyDim: base = 0.35
        case .zDark: base = 0.3
        case .cut: return 0
        }
        return base * min(1, max(0, ink.level))
    }

    /// 这一笔是**改写**遮罩（不管底下画了什么，这里就是这个不透明度），还是叠上去。
    ///
    /// 切口要改写成 0 —— 这就是「眼皮用裁剪实现」。粉色内耳也要改写：
    /// 它画在白耳朵上面，叠上去还是全不透明，内耳就没了；改写成 0.45 才看得出一道浅槽。
    public static func replaces(_ ink: CCFaceInk) -> Bool {
        ink.tone == .cut || ink.tone == .pink
    }
}

// MARK: - 绘制清单

nonisolated public struct CCPt: Sendable, Equatable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// 一笔。坐标是原屏 480×480，y 朝下。**按顺序画**（后画的盖住先画的 ——
/// 眼皮就是一块后画的黑色矩形）。
nonisolated public enum CCFacePrim: Sendable, Equatable {
    case roundRect(x: Double, y: Double, w: Double, h: Double, r: Double, CCFaceInk)
    case rect(x: Double, y: Double, w: Double, h: Double, CCFaceInk)
    case triangle(CCPt, CCPt, CCPt, CCFaceInk)
    case circle(cx: Double, cy: Double, r: Double, CCFaceInk)
    /// 圆环的一段，Arduino_GFX `fillArc` 的约定：r1/r2 两个半径之间，
    /// 角度单位是度、0 在三点钟方向、**y 朝下所以 270° 在正上方**（180→360 是上半圈，
    /// 也就是「^ ^」那种弯眼）。
    case arc(cx: Double, cy: Double, r1: Double, r2: Double, from: Double, to: Double, CCFaceInk)
    /// 原固件 `drawRotatedPill`：长 len、粗 thick 的圆头条，绕中心转 deg 度（y 朝下＝顺时针）。
    case pill(cx: Double, cy: Double, len: Double, thick: Double, deg: Double, CCFaceInk)
    /// 1 px 细线（猫胡须）。
    case line(CCPt, CCPt, CCFaceInk)
    case polygon([CCPt], CCFaceInk)
}

// MARK: - 原固件的十种视觉状态

/// 原固件 `GrokSt`（grokface.h）。眨眼节奏、表情池、grok 状态表都按它查。
nonisolated public enum CCFaceLook: Int, Sendable, Equatable, CaseIterable {
    case off = 0, idle, working, needs, done, listening, bored, surprised, petting, offline

    /// 我们的八张脸 → 他们的状态。`bored` / `surprised` 暂时没有对应信号（没人理、被拿起来），
    /// 表照抄完整，留着以后接。
    public static func from(_ mood: CCFaceMood) -> CCFaceLook {
        switch mood {
        case .asleep: .off
        case .searching: .offline
        case .waiting: .needs
        case .listening: .listening
        // 原固件没有「在说话」—— 借「被抚摸」：弯眼＋脸红＋轻晃，最像开心地在讲。
        case .speaking: .petting
        case .working: .working
        case .done: .done
        case .idle: .idle
        }
    }
}

/// 原固件 grokface.cpp 的 `GCFG`（Main.dc.html CFG 第三版）。**时间单位换成了秒**，其余照抄。
nonisolated public struct CCGrokCfg: Sendable, Equatable {
    /// GrokBot 表情编号（原表定长 3、靠 nPool 截断；这里直接存有效的那几个）。
    public var pool: [Int]
    /// 换表情的间隔区间。
    public var swMin: Double, swMax: Double
    /// 眨眼间隔区间；都为 0 ＝ 不眨眼。
    public var blMin: Double, blMax: Double
    public var col: CCFaceInk
    /// 眼神漂移幅度（原表 drift10 / 10）。
    public var drift: Double
    /// 干活时的扫视。
    public var dart: Bool
    /// 干完时的弹跳。
    public var hop: Bool
    /// 整脸上下偏移（px）。
    public var dy: Double
}

nonisolated public enum CCFaceMotion {
    // MARK: 几何常量（face.cpp）

    /// 两眼中心，关于 x=240 对称。
    public static let eyeLX: Double = 168
    public static let eyeRX: Double = 312
    /// **眼睛下沿固定在这里** —— 换状态只动上眼皮（原固件文件头第一句话）。
    public static let eyeBottom: Double = 271
    public static let eyeW: Double = 92

    // MARK: grok 状态表（grokface.cpp GCFG，毫秒 → 秒）

    public static func grokTable(_ look: CCFaceLook) -> CCGrokCfg {
        let W = CCFaceInk.grokWhite
        switch look {
        case .off: return .init(pool: [13, 22, 4], swMin: 6, swMax: 10, blMin: 0, blMax: 0,
                                col: CCFaceInk.grokSleep, drift: 0, dart: false, hop: false, dy: 0)
        case .idle: return .init(pool: [10, 1, 19], swMin: 8, swMax: 15, blMin: 5, blMax: 12,
                                 col: W, drift: 1.0, dart: false, hop: false, dy: 0)
        case .working: return .init(pool: [13, 4, 22], swMin: 2.2, swMax: 4, blMin: 0, blMax: 0,
                                    col: W, drift: 0.4, dart: true, hop: false, dy: 0)
        // 原表 dy = -56：给板子上的「批准」气泡让位。我们没有气泡，不移（见类型文档）。
        case .needs: return .init(pool: [20, 1], swMin: 1.6, swMax: 2.8, blMin: 4, blMax: 7.5,
                                  col: W, drift: 0.6, dart: false, hop: false, dy: 0)
        case .done: return .init(pool: [2, 17, 11], swMin: 1.2, swMax: 2.2, blMin: 0, blMax: 0,
                                 col: W, drift: 0.3, dart: false, hop: true, dy: 0)
        case .listening: return .init(pool: [0, 8], swMin: 2.5, swMax: 4.5, blMin: 4.5, blMax: 9,
                                      col: W, drift: 0.5, dart: false, hop: false, dy: 0)
        case .bored: return .init(pool: [5, 23, 14], swMin: 6, swMax: 12, blMin: 7, blMax: 15,
                                  col: W, drift: 1.2, dart: false, hop: false, dy: 0)
        case .surprised: return .init(pool: [20, 1], swMin: 0.9, swMax: 1.6, blMin: 1.2, blMax: 3,
                                      col: W, drift: 0, dart: false, hop: false, dy: 0)
        case .petting: return .init(pool: [2, 17], swMin: 1.5, swMax: 3, blMin: 0, blMax: 0,
                                    col: W, drift: 0.2, dart: false, hop: false, dy: 0)
        case .offline: return .init(pool: [16, 7], swMin: 5, swMax: 9, blMin: 6, blMax: 12,
                                    col: CCFaceInk.grokGone, drift: 0.2, dart: false, hop: false, dy: 0)
        }
    }

    // MARK: 眨眼（grokface.cpp petBlinkTick）

    /// 一次眨眼 320 ms：前 134 ms 闭（42%），后 186 ms 睁（58%）。
    public static let blinkDuration: Double = 0.320
    public static let blinkClose: Double = 0.134

    /// 眨眼间隔区间（秒）。nil ＝ 这个状态不眨眼。
    ///
    /// `pill`：五套胶囊皮肤。它们干活时也眨（眼睛够高看得出来），固定 3–6 秒；
    /// grok 干活时眼睛是细线，不眨 —— 原固件 `legacy && st == GK_WORKING` 那一句。
    public static func blinkRange(_ look: CCFaceLook, pill: Bool) -> (lo: Double, hi: Double)? {
        if pill && look == .working { return (3, 6) }
        let g = grokTable(look)
        guard g.blMin > 0 else { return nil }
        return (g.blMin, g.blMax)
    }

    /// 眨眼曲线，`p` 是从开始眨算起的秒数。0 ＝ 全睁、1 ＝ 闭到底。
    public static func blinkCurve(_ p: Double) -> Double {
        guard p >= 0, p < blinkDuration else { return 0 }
        if p < blinkClose { return p / blinkClose }
        return 1 - (p - blinkClose) / (blinkDuration - blinkClose)
    }

    /// 这一刻眨到几成。
    ///
    /// 原固件的调度：**一进入新状态就在不久之后眨一次**（`lo·2/5 … hi·3/5` 之间，
    /// 「never look frozen」），之后每次眨眼开始时排下一次：`+ rnd(lo, hi)`。
    /// 这里从 `since`（进入该状态的时刻）起按同样的规则重放。
    ///
    /// 重放每满一小时重新起算（窗口内最多几百步），免得一个挂了一整天的状态
    /// 每帧都要从早上重放到晚上。代价是每小时节奏接缝一次，看不出来。
    public static func blink(look: CCFaceLook, pill: Bool, since: Double, t: Double, seed: UInt64) -> Double {
        guard let r = blinkRange(look, pill: pill), t.isFinite, since.isFinite, t >= since else { return 0 }
        let w = ((t - since) / window).rounded(.down)
        let anchor = since + w * window
        let key = streamKey(seed, since, w, salt: 0xB11E &+ UInt64(look.rawValue))
        var next: Double
        if w == 0 {
            next = since + lerp(r.lo * 0.4, r.hi * 0.6, unit(key, 0))
        } else {
            next = anchor + r.hi * unit(key, 0)
        }
        var i: Int64 = 1
        while next + blinkDuration <= t {
            next += lerp(r.lo, r.hi, unit(key, i))
            i += 1
        }
        return t >= next ? blinkCurve(t - next) : 0
    }

    // MARK: 扫视（face.cpp dartOffset）

    /// 干活时的扫视：左看、停、右看、停、回正，一圈 3.8 秒。返回 px。
    public static func dart(_ t: Double) -> Double {
        let p = frac(t / 3.8)
        if p < 0.18 { return -14 * ease(p / 0.18) }
        if p < 0.38 { return -14 }
        if p < 0.52 { return -14 + 26 * ease((p - 0.38) / 0.14) }
        if p < 0.72 { return 12 }
        if p < 0.88 { return 12 - 12 * ease((p - 0.72) / 0.16) }
        return 0
    }

    // MARK: 表情池（face.cpp EyeVar / variantOf / varTick）

    /// 五套胶囊皮肤每个状态的几张脸。只有数在变（开合高度、宽度、基线、晃动幅度），
    /// 换脸用 180 ms 缓动过渡，不是硬切。
    nonisolated public struct EyeVar: Sendable, Equatable {
        public var wL: Double, hL: Double, wR: Double, hR: Double
        /// 基线相对 `eyeBottom` 的偏移（done 的弯眼是 -25）。
        public var dy: Double
        /// bored ＝ 漂移幅度 | done ＝ 弹跳 | needs ＝ 跟着问号一起跳。
        public var aux: Double
        /// 只有 done 用：0 ＝ 弯眼，1 ＝ 笑开的宽胶囊。
        public var pill: Double
    }

    public static func variantCount(_ look: CCFaceLook) -> Int {
        switch look {
        case .idle, .working, .needs, .done, .bored: 3
        default: 1
        }
    }

    /// 原表照抄（lead 2026-09-19 的版本）。`left` 是挑中那一刻抛的硬币 ——
    /// 不对称的几张脸才不会永远朝同一边歪。
    public static func variantOf(_ look: CCFaceLook, _ v: Int, left: Bool) -> EyeVar {
        let W = eyeW
        switch look {
        case .idle:
            if v == 1 { return EyeVar(wL: W, hL: left ? 46 : 34, wR: W, hR: left ? 34 : 46, dy: 0, aux: 0, pill: 0) }
            if v == 2 { return EyeVar(wL: W, hL: 30, wR: W, hR: 30, dy: 0, aux: 0, pill: 0) }
            return EyeVar(wL: W, hL: 42, wR: W, hR: 42, dy: 0, aux: 0, pill: 0)
        case .working:
            if v == 1 { return EyeVar(wL: W - 12, hL: 70, wR: W - 12, hR: 70, dy: 0, aux: 0, pill: 0) }
            if v == 2 { return EyeVar(wL: W, hL: left ? 40 : 58, wR: W, hR: left ? 58 : 40, dy: 0, aux: 0, pill: 0) }
            return EyeVar(wL: W, hL: 58, wR: W, hR: 58, dy: 0, aux: 0, pill: 0)
        case .needs:
            if v == 1 { return EyeVar(wL: 96, hL: 96, wR: 96, hR: 96, dy: 0, aux: 4, pill: 0) }
            if v == 2 { return EyeVar(wL: 106, hL: 110, wR: 106, hR: 110, dy: -4, aux: 0, pill: 0) }
            return EyeVar(wL: 106, hL: 106, wR: 106, hR: 106, dy: 0, aux: 0, pill: 0)
        case .done:
            if v == 1 { return EyeVar(wL: 96, hL: 32, wR: 96, hR: 32, dy: -25, aux: 6, pill: 0) }
            if v == 2 { return EyeVar(wL: 106, hL: 80, wR: 106, hR: 80, dy: 0, aux: 0, pill: 1) }
            return EyeVar(wL: 84, hL: 28, wR: 84, hR: 28, dy: -25, aux: 10, pill: 0)
        case .bored:
            if v == 1 { return EyeVar(wL: W, hL: left ? 8 : 30, wR: W, hR: left ? 30 : 8, dy: 0, aux: 10, pill: 0) }
            if v == 2 { return EyeVar(wL: W, hL: 34, wR: W, hR: 34, dy: 0, aux: 4, pill: 0) }
            return EyeVar(wL: W, hL: 34, wR: W, hR: 34, dy: 0, aux: 10, pill: 0)
        default:
            return EyeVar(wL: W, hL: 42, wR: W, hR: 42, dy: 0, aux: 0, pill: 0)
        }
    }

    /// 换脸间隔（`vCadence`）：跟 grok 共用一张表；needs 至少 3 秒 ——
    /// 原话「批准气泡是手指要瞄准的目标，上面那张脸得稳」。
    public static func variantCadence(_ look: CCFaceLook) -> (lo: Double, hi: Double) {
        let g = grokTable(look)
        var lo = g.swMin, hi = g.swMax
        if lo <= 0 || hi < lo { lo = 6; hi = 12 }
        if look == .needs {
            lo = max(lo, 3)
            if hi < lo + 1.2 { hi = lo + 1.2 }
        }
        return (lo, hi)
    }

    public static let variantMorph: Double = 0.180

    /// 此刻显示的那张脸（含 180 ms 过渡）＋ 当前下标。
    /// 进入状态时从 V0 开始、不过渡；之后按间隔随机换，**绝不连着两次同一张**。
    public static func variant(look: CCFaceLook, since: Double, t: Double, seed: UInt64) -> (disp: EyeVar, index: Int) {
        let n = variantCount(look)
        guard n > 1, t.isFinite, since.isFinite, t >= since else {
            return (variantOf(look, 0, left: false), 0)
        }
        let cad = variantCadence(look)
        let w = ((t - since) / window).rounded(.down)
        let anchor = since + w * window
        let key = streamKey(seed, since, w, salt: 0x7A11 &+ UInt64(look.rawValue))
        var idx = w == 0 ? 0 : Int(unit(key, 0) * Double(n)) % n
        var dst = variantOf(look, idx, left: unit(key, 1) < 0.5)
        var src = dst
        var morphAt = -Double.infinity
        var switchAt = anchor + lerp(cad.lo, cad.hi, unit(key, 2))
        var i: Int64 = 3
        while switchAt <= t {
            let v = (idx + 1 + Int(unit(key, i) * Double(n - 1)) % (n - 1)) % n
            idx = v
            src = dst                       // 换脸间隔 ≥1.2 s ≫ 180 ms，上一张早就到位了
            dst = variantOf(look, v, left: unit(key, i + 1) < 0.5)
            morphAt = switchAt
            switchAt += lerp(cad.lo, cad.hi, unit(key, i + 2))
            i += 3
        }
        let p = t - morphAt
        guard p < variantMorph else { return (dst, idx) }
        let k = ease(p / variantMorph)
        return (EyeVar(wL: lerp(src.wL, dst.wL, k), hL: lerp(src.hL, dst.hL, k),
                       wR: lerp(src.wR, dst.wR, k), hR: lerp(src.hR, dst.hR, k),
                       dy: lerp(src.dy, dst.dy, k), aux: lerp(src.aux, dst.aux, k),
                       pill: lerp(src.pill, dst.pill, k)), idx)
    }

    // MARK: grok 表情与弹簧（grokface.cpp）

    /// 阻尼弹簧：ω = 2π·3.5 Hz，ζ = 0.72，约 280 ms、带一点过冲。
    public static let springOmega: Double = 2 * .pi * 3.5
    public static let springZeta: Double = 0.72

    /// 0 → 1 的弹簧进度，初速 0（原固件每次换表情都 `s_pos = 0; s_vel = 0`）。
    ///
    /// 原固件用 16 ms 子步的欧拉积分推进（单步 50 ms 会发散），这里直接用欠阻尼的解析解 ——
    /// 同一条曲线，但不依赖帧率。到 0.8 秒时离终点已不到万分之一，直接贴到 1
    /// （原固件的「落定」判据：位置 > 0.999 且速度 < 0.05）。
    public static func spring(_ tau: Double) -> Double {
        guard tau > 0 else { return 0 }
        guard tau < 0.8 else { return 1 }
        let z = springZeta, w = springOmega
        let s = (1 - z * z).squareRoot()
        let wd = w * s
        return 1 - exp(-z * w * tau) * (cos(wd * tau) + z / s * sin(wd * tau))
    }

    /// 此刻 grok 在变向哪个表情：(从哪个, 到哪个, 什么时候开始变)。
    ///
    /// 进入状态时取池子第一个；如果进来之前显示的正好就是它，就不变形（原固件 `setExpr`
    /// 的早退）。`enteredFrom` 由视图记下（进入这个状态那一刻正显示的表情）；
    /// nil ＝ 冷启动，直接弹到位（原固件 `s_cur < 0` 那一支）。
    public static func grokExpression(look: CCFaceLook, since: Double, t: Double, seed: UInt64,
                                      enteredFrom: Int?) -> (from: Int?, to: Int, at: Double) {
        let g = grokTable(look)
        let pool = g.pool
        let first = pool[0]
        guard t.isFinite, since.isFinite, t >= since else { return (nil, first, since) }
        let w = ((t - since) / window).rounded(.down)
        let anchor = since + w * window
        let key = streamKey(seed, since, w, salt: 0x6A0C &+ UInt64(look.rawValue))
        var cur = w == 0 ? first : pool[Int(unit(key, 0) * Double(pool.count)) % pool.count]
        var from: Int? = (w == 0 && enteredFrom != first) ? enteredFrom : nil
        var at = anchor
        var switchAt = anchor + lerp(g.swMin, g.swMax, unit(key, 1))
        var i: Int64 = 2
        while pool.count > 1, switchAt <= t {
            let others = pool.filter { $0 != cur }
            let next = others[Int(unit(key, i) * Double(others.count)) % others.count]
            from = cur
            cur = next
            at = switchAt
            switchAt += lerp(g.swMin, g.swMax, unit(key, i + 1))
            i += 2
        }
        return (from, cur, at)
    }

    // MARK: - 一帧

    nonisolated public struct Input: Sendable {
        public var mood: CCFaceMood
        public var skin: CCFaceSkin
        /// 秒，任意零点（视图传 `timeIntervalSinceReferenceDate`）。
        public var t: Double
        /// 进入当前心情的时刻（同一零点）。眨眼调度、换脸、出汗都从它算起。
        public var since: Double
        /// 按房间名给（`seed(for:)`），五张脸才不会同时眨眼。
        public var seed: UInt64
        /// 小尺寸：不画问号、打字点、zz、汗滴、麦克风条、脸红、断线短杠。
        public var compact: Bool
        /// 系统「减弱动态效果」：**只换形状** —— 不扫视、不浮动、不眨眼、不换脸、
        /// 道具不跳。形状本身（睁多大、弯眼、问号）照样按状态换。
        public var reduceMotion: Bool
        public var typingDots: Int
        /// grok：进入当前心情那一刻正显示的表情（见 `grokExpression`）。
        public var grokFrom: Int?

        public init(mood: CCFaceMood, skin: CCFaceSkin, t: Double, since: Double, seed: UInt64,
                    compact: Bool = false, reduceMotion: Bool = false, typingDots: Int = 3,
                    grokFrom: Int? = nil) {
            self.mood = mood; self.skin = skin; self.t = t; self.since = since; self.seed = seed
            self.compact = compact; self.reduceMotion = reduceMotion; self.typingDots = typingDots
            self.grokFrom = grokFrom
        }
    }

    /// 一帧的结果：绘制清单＋几个给测试和读屏看的参数。
    nonisolated public struct Scene: Sendable, Equatable {
        public var look: CCFaceLook
        public var prims: [CCFacePrim]
        /// 眨眼程度 0…1（0 ＝ 没在眨）。
        public var blink: Double
        /// 上眼皮开合系数：`1 − 0.96·blink`（原固件闭眼也留 4%）。
        public var lidOpen: Double
        /// 眼珠水平 / 垂直偏移（px）—— 扫视、grok 的漂移。
        public var gazeX: Double
        public var gazeY: Double
        /// 整体浮动（px，正＝往下）—— 呼吸、弹跳、轻晃。
        public var bob: Double
        /// 这一帧画了心情道具（问号、打字点、zz、汗滴、麦克风条、脸红、断线短杠）没有。
        public var hasProps: Bool
        /// grok 此刻显示的表情编号（非 grok 为 nil）。
        public var grokExpr: Int?
    }

    public static func scene(_ i: Input) -> Scene {
        var b = Builder(skin: i.skin, t: i.t, reduce: i.reduceMotion)
        let look = CCFaceLook.from(i.mood)
        let t = i.t
        let mo: Double = i.reduceMotion ? 0 : 1        // 动作幅度总开关
        let grok = i.skin == .grok

        b.skinProps()

        let blinkK = i.reduceMotion ? 0 : blink(look: look, pill: !grok, since: i.since, t: t, seed: i.seed)
        let bf = 1 - 0.96 * blinkK
        let V = i.reduceMotion ? variantOf(look, 0, left: false)
                               : variant(look: look, since: i.since, t: t, seed: i.seed).disp
        var gazeX = 0.0, gazeY = 0.0, bob = 0.0
        var props = false
        var grokExpr: Int?

        if grok {
            let e = grokEyes(b: &b, look: look, input: i, blinkK: blinkK)
            gazeX = e.gx; gazeY = e.gy; grokExpr = e.expr
        }

        switch look {
        case .off:                                   // 睡着：两条平的横条 ＋ zz
            bob = 4 * sin(t * 1.3) * mo
            if !grok {
                b.p.append(.roundRect(x: 136, y: 230 + bob, w: 64, h: 10, r: 5, CCFaceInk.eye))
                b.p.append(.roundRect(x: 280, y: 230 + bob, w: 64, h: 10, r: 5, CCFaceInk.eye))
            } else { bob = 0 }
            if !i.compact { b.zz(); props = true }

        case .idle:                                  // 犯困的半睁眼，慢慢呼吸
            if !grok {
                // 呼吸改的是眼皮开合（高度），不是位置 —— 所以 bob 留 0，下沿纹丝不动。
                let wave = 3 * sin(t * 1.2) * mo
                b.eyeLidded(eyeLX, (V.hL + wave) * bf, V.dy)
                b.eyeLidded(eyeRX, (V.hR + wave) * bf, V.dy)
            }

        case .working:                               // 眯眼 ＋ 扫视 ＋ 打字点
            var bb = 4 * sin(.pi * frac(t / 4.8)) * mo
            if grok { bb = 0 } else {               // grok 的扫视由引擎自己管
                let d = dart(t) * mo
                gazeX = d
                b.eyePill(eyeLX, V.wL, V.hL * bf, d, bb + V.dy)
                b.eyePill(eyeRX, V.wR, V.hR * bf, d, bb + V.dy)
            }
            bob = bb
            if !i.compact {
                b.typingDots(n: max(1, i.typingDots), dy: bb)
                b.sweat(workedFor: t - i.since)
                props = true
            }

        case .needs:                                 // 瞪大 ＋ 跳动的问号
            if !grok {
                bob = V.dy - V.aux * abs(sin(t * 5)) * mo   // V1 跟着问号一起跳
                b.eyePill(eyeLX, V.wL, V.hL * bf, 0, bob)
                b.eyePill(eyeRX, V.wR, V.hR * bf, 0, bob)
            }
            if !i.compact {
                let qy = 100 - 8 * abs(sin(t * 5)) * mo
                b.glyph(Self.question, x: 362, y: qy, scale: 5, CCFaceInk.eye)
                props = true
            }

        case .done:                                  // 开心的弯眼，一跳一跳
            if !grok {
                let hop = -(V.aux * sin(.pi * frac(t / 2))) * mo
                bob = V.dy + hop                     // 弯眼比胶囊高 25 px
                if V.pill >= 0.5 {                   // V2「笑开」：宽胶囊
                    b.eyePill(eyeLX, V.wL, V.hL * bf, 0, bob)
                    b.eyePill(eyeRX, V.wR, V.hR * bf, 0, bob)
                } else {
                    b.p.append(.arc(cx: eyeLX, cy: eyeBottom + bob, r1: V.wL / 2, r2: V.hL,
                                    from: 180, to: 360, CCFaceInk.eye))
                    b.p.append(.arc(cx: eyeRX, cy: eyeBottom + bob, r1: V.wR / 2, r2: V.hR,
                                    from: 180, to: 360, CCFaceInk.eye))
                }
            }

        case .listening:                             // 全睁 ＋ 麦克风条
            if !grok {
                b.eyePill(eyeLX, eyeW, eyeW * bf, 0, 0)
                b.eyePill(eyeRX, eyeW, eyeW * bf, 0, 0)
            }
            if !i.compact { b.micBars(); props = true }

        case .offline:                               // 灰色耷拉眼 ＋ 断开的链接
            if !grok {
                b.p.append(.pill(cx: eyeLX, cy: 242, len: 84, thick: 34, deg: -8, CCFaceInk.greyEye))
                b.p.append(.pill(cx: eyeRX, cy: 242, len: 84, thick: 34, deg: 8, CCFaceInk.greyEye))
            }
            if !i.compact {
                b.p.append(.roundRect(x: 212, y: 300, w: 20, h: 6, r: 3, CCFaceInk.greyDim))
                b.p.append(.roundRect(x: 248, y: 308, w: 20, h: 6, r: 3, CCFaceInk.greyDim))
                props = true
            }

        case .petting:                               // 弯眼 ＋ 脸红 ＋ 轻晃
            var bb = 3 * sin(t * 8) * mo
            if grok { bb = 0 } else {               // grok 的引擎有自己的漂移
                b.p.append(.arc(cx: eyeLX, cy: 250 + bb, r1: 46, r2: 30, from: 180, to: 360, CCFaceInk.eye))
                b.p.append(.arc(cx: eyeRX, cy: 250 + bb, r1: 46, r2: 30, from: 180, to: 360, CCFaceInk.eye))
            }
            bob = bb
            if !i.compact {
                let blush = CCFaceInk.battRed.dim(0.45)
                b.p.append(.circle(cx: eyeLX - 66, cy: 272 + bb, r: 11, blush))
                b.p.append(.circle(cx: eyeRX + 66, cy: 272 + bb, r: 11, blush))
                props = true
            }

        case .surprised:                             // 被拿起来：大椭圆眼 ＋ o 形嘴（grok 无嘴）
            if !grok {
                b.eyePill(eyeLX, 100, 114, 0, 0)
                b.eyePill(eyeRX, 100, 114, 0, 0)
                b.p.append(.circle(cx: 240, cy: 324, r: 12, CCFaceInk.eye))
                b.p.append(.circle(cx: 240, cy: 324, r: 7, CCFaceInk.bg))
            }

        case .bored:                                 // 没人理：沉重的眼皮，慢慢飘
            if !grok {
                let drift = V.aux * sin(t * 1.2) * mo
                gazeX = drift
                b.eyeLidded(eyeLX + drift, V.hL * bf, V.dy)
                b.eyeLidded(eyeRX + drift, V.hR * bf, V.dy)
            }
            if !i.compact {
                for k in 0..<3 { b.glyph(Self.dot, x: 352 + Double(k) * 18, y: 140, scale: 3, CCFaceInk.greyText) }
                props = true
            }
        }

        return Scene(look: look, prims: b.p, blink: blinkK, lidOpen: bf, gazeX: gazeX, gazeY: gazeY,
                     bob: bob, hasProps: props, grokExpr: grokExpr)
    }

    /// grok 的一对眼睛（`grokDrawEyes`）：表情之间按点插值变形 ＋ 两条慢正弦的眼神漂移
    /// ＋ 干活扫视 ＋ 干完弹跳；眨眼 ＝ 绕质心纵向压扁。
    static func grokEyes(b: inout Builder, look: CCFaceLook, input i: Input, blinkK: Double)
        -> (gx: Double, gy: Double, expr: Int)
    {
        let g = grokTable(look)
        let t = i.t
        let mo: Double = i.reduceMotion ? 0 : 1
        let e: (from: Int?, to: Int, at: Double) = i.reduceMotion
            ? (nil, g.pool[0], i.since)
            : grokExpression(look: look, since: i.since, t: t, seed: i.seed, enteredFrom: i.grokFrom)
        let x = e.from == nil ? 1 : spring(t - e.at)
        var gx = g.drift * mo * (14 * sin(t * 0.37) + 6 * sin(t * 0.91))
        var gy = g.drift * mo * 8 * sin(t * 0.53 + 1.3)
        if g.dart && !i.reduceMotion {
            let ph = frac(t / 2.4)
            gx += ph < 0.12 ? -18 : (ph < 0.30 ? 14 : 0)
        }
        if g.hop && !i.reduceMotion { gy -= 10 * abs(sin(.pi * frac(t / 2))) }
        gy += g.dy
        let sy = 1 - 0.96 * blinkK
        let shapes = CCFaceGrokEyes.shapes
        guard e.to < shapes.count else { return (gx, gy, e.to) }
        for eye in 0..<2 {
            let dst = shapes[e.to][eye]
            let src = shapes[min(e.from ?? e.to, shapes.count - 1)][eye]
            let n = min(dst.count, src.count) / 2
            var disp = [Double](repeating: 0, count: n * 2)
            var cy = 0.0
            for k in 0..<(n * 2) {
                disp[k] = src[k] + (dst[k] - src[k]) * x
                if k % 2 == 1 { cy += disp[k] }
            }
            cy /= Double(max(1, n))
            var pts: [CCPt] = []
            pts.reserveCapacity(n)
            for k in 0..<n {
                pts.append(CCPt(disp[k * 2] * 0.25 + gx, (cy + (disp[k * 2 + 1] - cy) * sy) * 0.25 + gy))
            }
            b.p.append(.polygon(pts, g.col))
        }
        return (gx, gy, e.to)
    }

    // MARK: - 画笔（face.cpp 里那几个 draw* 函数）

    nonisolated struct Builder {
        let skin: CCFaceSkin
        let t: Double
        let reduce: Bool
        var p: [CCFacePrim] = []

        init(skin: CCFaceSkin, t: Double, reduce: Bool) {
            self.skin = skin; self.t = t; self.reduce = reduce
            p.reserveCapacity(24)
        }

        /// `drawEyePill`：对称胶囊，**下沿钉在 eyeBottom**。全睁（h == w）就是圆。
        mutating func eyePill(_ cx: Double, _ w: Double, _ hIn: Double, _ dx: Double, _ dy: Double,
                              _ col: CCFaceInk = CCFaceInk.eye) {
            let h = max(8, hIn)
            // robo 是方眼，其余是圆头胶囊
            let r = min(w, h) / (skin == .robo ? 6 : 2)
            let x = cx - w / 2 + dx, y = CCFaceMotion.eyeBottom + dy - h
            p.append(.roundRect(x: x, y: y, w: w, h: h, r: r, col))
            roboShine(x, y, w, h)
        }

        /// `drawEyeLidded`：被一块平的上眼皮压住的眼睛。保持全宽、底部大圆角
        /// （设计稿 10/32 的圆角搭配），而不是越眯越窄的半圆。
        mutating func eyeLidded(_ cx: Double, _ openIn: Double, _ dy: Double, _ col: CCFaceInk = CCFaceInk.eye) {
            let openH = max(8, openIn)
            let W = CCFaceMotion.eyeW
            let bottom = CCFaceMotion.eyeBottom + dy
            let h = openH + 24                     // 留出余量，底部圆角才不被切掉
            let r = min(skin == .robo ? 12 : 32, min(W, h) / 2)
            p.append(.roundRect(x: cx - W / 2, y: bottom - h, w: W, h: h, r: r, col))
            p.append(.rect(x: cx - W / 2 - 1, y: bottom - h - 1, w: W + 2, h: 25, CCFaceInk.bg))
            roboShine(cx - W / 2, bottom - openH, W, openH)
        }

        /// `drawRoboShine`：一块黑色小方缺口在眼睛里缓慢漂，每 ~4.2 秒抽一下跳到对角
        /// （「像素在刷新」）。眼睛太小（眯着）时不画。
        mutating func roboShine(_ left: Double, _ top: Double, _ w: Double, _ h: Double) {
            guard skin == .robo, w >= 50, h >= 36 else { return }
            let s: Double = h >= 56 ? 17 : 13
            let nx: Double, ny: Double
            if !reduce && CCFaceMotion.frac(t / 4.2) * 4.2 < 0.160 {
                nx = left + w - s - 12
                ny = top + h - s - 12
            } else {
                let m: Double = reduce ? 0 : 1
                nx = left + 12 + (6 * sin(t * 1.1) * m).rounded(.towardZero)
                ny = top + 10 + (5 * sin(t * 1.7 + 1.3) * m).rounded(.towardZero)
            }
            p.append(.roundRect(x: nx, y: ny, w: s, h: s, r: 4, CCFaceInk.bg))
        }

        /// `drawSkinProps`：每套皮肤的头饰，画在眼睛底下，所有状态都戴着。
        mutating func skinProps() {
            let E = CCFaceInk.eye
            let lx = CCFaceMotion.eyeLX, rx = CCFaceMotion.eyeRX
            switch skin {
            case .kitty:
                // 两只歪着的三角耳 ＋ 每边三根胡须
                p.append(.triangle(CCPt(lx - 44, 152), CCPt(lx + 14, 148), CCPt(lx - 22, 84), E))
                p.append(.triangle(CCPt(rx + 44, 152), CCPt(rx - 14, 148), CCPt(rx + 22, 84), E))
                for k in 0..<3 {
                    let y = 234 + Double(k) * 18
                    p.append(.line(CCPt(52, y + 6), CCPt(108, y), CCFaceInk.greyText))
                    p.append(.line(CCPt(372, y), CCPt(428, y + 6), CCFaceInk.greyText))
                }
            case .bunny:
                // 一只立着（粉色内耳），一只折下来、耳尖往外耷拉 —— 坐标取自换装间画稿
                p.append(.pill(cx: 158, cy: 103, len: 148, thick: 36, deg: 82, E))
                p.append(.pill(cx: 158, cy: 101, len: 96, thick: 16, deg: 82, CCFaceInk.pink))
                p.append(.pill(cx: 318, cy: 130, len: 92, thick: 36, deg: 98, E))
                p.append(.pill(cx: 332, cy: 91, len: 62, thick: 34, deg: 168, E))
                p.append(.pill(cx: 332, cy: 92, len: 40, thick: 16, deg: 168, CCFaceInk.pink))
            case .sprout:
                // 绿芽：两段微 S 形的茎 ＋ 两片叶子
                let G = CCFaceInk.green
                p.append(.pill(cx: 239, cy: 138, len: 34, thick: 9, deg: 96, G))
                p.append(.pill(cx: 241, cy: 116, len: 30, thick: 9, deg: 84, G))
                p.append(.pill(cx: 214, cy: 98, len: 48, thick: 27, deg: -35, G))
                p.append(.pill(cx: 266, cy: 98, len: 48, thick: 27, deg: 35, G))
            // robo 没有头饰：整个机器人都在方眼和那块漂移的高光里。grok 是纯黑脸。
            case .classic, .robo, .grok:
                break
            }
        }

        /// `drawTypingDots`：一排点按顺序起伏（1.3 秒一轮、相邻错 220 ms）。
        mutating func typingDots(n: Int, dy: Double) {
            for k in 0..<n {
                var lvl = 0.25, lift = 0.0
                if reduce {
                    lvl = 0.6                       // 不轮转：全部同亮度
                } else {
                    let ph = CCFaceMotion.fmod1(t + 13 - Double(k) * 0.220, 1.3)
                    if ph < 0.650 {
                        let kk = sin(.pi * ph / 0.650)
                        lvl = 0.25 + 0.75 * kk
                        lift = (4 * kk).rounded(.towardZero)
                    }
                }
                let x = 240 - Double(n - 1) * 14 + Double(k) * 28
                p.append(.circle(cx: x, cy: 322 + dy - lift, r: 7, CCFaceInk.eye.dim(lvl)))
            }
        }

        /// `drawSweat`：连续干活满 3 分钟后，每 ~25 秒滑下一滴汗（彩蛋，不是常驻道具）。
        mutating func sweat(workedFor w: Double) {
            guard !reduce, w >= 180 else { return }
            let ph = CCFaceMotion.fmod1(w, 25)
            guard ph <= 2.2 else { return }
            let y = 130 + (24 * ph / 2.2).rounded(.towardZero)
            let fade = ph > 1.6 ? 1 - (ph - 1.6) / 0.6 : 1
            let col = CCFaceInk.sweat.dim(fade)
            p.append(.triangle(CCPt(361, y), CCPt(355, y + 8), CCPt(367, y + 8), col))
            p.append(.circle(cx: 361, cy: y + 10, r: 7, col))
        }

        /// `drawZz`：两个 z 往上飘、变淡，3.6 秒一轮。
        mutating func zz() {
            let ph = reduce ? 0 : CCFaceMotion.frac(t / 3.6)
            let rise = (ph * 32).rounded(.down)
            glyph(CCFaceMotion.zee, x: 346, y: 132 - rise, scale: 4, CCFaceInk.zLight.dim(1 - 0.5 * ph))
            glyph(CCFaceMotion.zee, x: 378, y: 100 - rise - (rise / 2).rounded(.down), scale: 3,
                  CCFaceInk.zDark.dim(1 - 0.5 * ph))
        }

        /// 「在听你说」底下那五根麦克风条。
        mutating func micBars() {
            let base: [Double] = [12, 24, 34, 22, 12]
            for k in 0..<5 {
                let wob = reduce ? 0 : (8 * sin(t * 12 + Double(k) * 1.1)).rounded(.towardZero)
                let h = max(6, base[k] + wob)
                p.append(.roundRect(x: 204 + Double(k) * 16, y: 333 - (h / 2).rounded(.towardZero),
                                    w: 8, h: h, r: 4, CCFaceInk.micBar))
            }
        }

        /// 原固件用 Adafruit GFX 自带的 5×7 点阵字（`setTextSize(n)` ＝ 每个点 n×n 像素）
        /// 写「?」「z」「...」。点阵是这里照着那个样子重画的；`(x, y)` 是字符格左上角。
        mutating func glyph(_ rows: [String], x: Double, y: Double, scale s: Double, _ col: CCFaceInk) {
            for (r, row) in rows.enumerated() {
                for (c, ch) in row.enumerated() where ch == "#" {
                    p.append(.rect(x: x + Double(c) * s, y: y + Double(r) * s, w: s, h: s, col))
                }
            }
        }
    }

    static let question = [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."]
    static let zee = [".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"]
    static let dot = [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."]

    // MARK: - 随机与小工具

    /// 重放窗口（见 `blink` 的文档）。
    static let window: Double = 3600

    /// 房间名 → 种子。**不用 `hashValue`**（Swift 的字符串哈希每次启动加盐，测试没法复现）。
    public static func seed(for name: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325   // FNV-1a
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h
    }

    /// 一条随机数流：种子 × 进入时刻 × 重放窗口 × 用途。进入时刻参与 ——
    /// 同一个房间两次进入同一状态，节奏也不一样。
    static func streamKey(_ seed: UInt64, _ since: Double, _ w: Double, salt: UInt64) -> UInt64 {
        let ms: Int64 = since.isFinite ? Int64((since * 1000).rounded()) : 0
        let a = UInt64(bitPattern: ms) &* 0xD6E8_FEB8_6659_FD93
        let b = UInt64(bitPattern: Int64(w)) &* 0xA076_1D64_78BD_642F
        let c = salt &* 0xE703_7ED1_A0B4_28DB
        return seed ^ a ^ b ^ c
    }

    /// [0, 1) 的确定性随机数。splitmix64。
    static func unit(_ key: UInt64, _ i: Int64) -> Double {
        var z = key &+ (UInt64(bitPattern: i) &+ 1) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    static func frac(_ x: Double) -> Double { x - x.rounded(.down) }
    /// 非负取模（原固件全是 uint32 毫秒的 `%`，不会有负数）。
    static func fmod1(_ x: Double, _ m: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }
    static func lerp(_ a: Double, _ b: Double, _ u: Double) -> Double { a + (b - a) * u }
    static func ease(_ u: Double) -> Double { u * u * (3 - 2 * u) }
}
