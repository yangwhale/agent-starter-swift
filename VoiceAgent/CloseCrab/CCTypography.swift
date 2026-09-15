import CoreText
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// 手写体。抄的是 grug（今年 ADA 的 Delight and Fun 获奖 app）那条路。
///
/// ## 抄的是什么
///
/// grug 那两个荷兰人一开始用现成的手写字体，觉得「太干净太精致」，
/// 于是在 app 里做了一块画字的画布，自己画完再写渲染引擎当字体系统用。
/// 他们的原话是：如果当时在这儿妥协了，grug 就只是「一个带可爱字体的语录 app」。
///
/// **我们抄的是那个决定，不是那套工程。** 自绘字库对我们不成立 ——
/// grug 是纯英文 app，26 个字母画完就够；我们界面上有中文，
/// 自己画一套中文字库根本不现实。
///
/// 所以这里退一步：**只给房间名和首字母图标换一套现成的手写体**，
/// 骨架（方块、波形、玻璃材质）一个字不动。六个 bot 的名字本来就都是拉丁字母
/// （bunny / jarvis / hulk / tommy / xiaoaitongxue / tianmaojingling），
/// 正好落在这套字覆盖得到的范围里。
///
/// ## 用的是 Patrick Hand，OFL 授权
///
/// 选它不选更花的那些（Caveat 之类）就一条理由：**11pt 还认得出来**。
/// 方块只有 54pt 宽，名字挤在底下那一行，草书体在这个尺寸上是一团毛。
/// 授权全文跟字体文件放在一起（`Resources/Fonts/PatrickHand-OFL.txt`），
/// OFL 要求随字体一起分发。
///
/// ## 为什么要自己注册、还要报告成不成功
///
/// `Font.custom("不存在的字体", size:)` **不会报错，会静默退回系统字体**。
/// 也就是说打包时漏了这个文件、或者 Info.plist 里路径写错，
/// 表现是「开关拨了没反应」，而没有任何一条日志会说为什么。
///
/// 所以这里做两件事：
/// 1. Info.plist 的 `UIAppFonts` 之外，再加一条**运行时注册**兜底 ——
///    资源被打平到 bundle 根目录还是保留了子目录，两种都能找到。
/// 2. 把结果存在 `isAvailable` 里，设置页直接显示。
///    **一个会静默失败的功能必须有个地方能看出它成没成。**
@MainActor
enum CCHandFont {
    /// PostScript 名。`Font.custom` 认的是这个，不是文件名，也不是 "Patrick Hand"。
    ///
    /// **`nonisolated` 不能省。** 这个枚举整体是 `@MainActor` 的，
    /// 而下面 `CCType` 是 `nonisolated` 的、要读这个常量 —— 不标的话
    /// 那一行会报「跨 actor 访问」。不可变 + Sendable，脱离 actor 是安全的。
    nonisolated static let postScriptName = "PatrickHand-Regular"

    /// 装进来了没有。设置页拿它显示状态。
    private(set) static var isAvailable = false

    /// 上一次注册发生了什么。只在出问题时给人看。
    private(set) static var lastNote = "还没检查"

    /// 启动时叫一次。幂等，重复调用不会重复注册。
    static func bootstrap() {
        if lookupSucceeds() {
            isAvailable = true
            lastNote = "系统已加载（Info.plist 那条路生效）"
            return
        }

        guard let url = locate() else {
            isAvailable = false
            lastNote = "在 app 包里找不到 PatrickHand-Regular.ttf"
            return
        }

        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        isAvailable = ok && lookupSucceeds()
        if isAvailable {
            lastNote = "运行时注册成功"
        } else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "未知原因"
            lastNote = "注册失败：\(reason)"
        }
    }

    // MARK: -

    /// 真的能按这个名字取到这个字吗。
    ///
    /// **不能只看 `CTFontCreateWithName` 返回非 nil** —— 取不到时它不报错，
    /// 会给你一个替补字体。所以要回头比对拿到的 PostScript 名。
    /// 这正是「静默退回系统字体」那个坑的检测点。
    private static func lookupSucceeds() -> Bool {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        return (CTFontCopyPostScriptName(font) as String) == postScriptName
    }

    /// 在 app 包里找字体文件。
    ///
    /// 三条路都试：Xcode 的资源拷贝默认会把文件**打平到包根目录**，
    /// 但同步文件夹组的行为随版本变过，保留子目录的情况也出现过。
    /// 最后那条是兜底 —— 按前缀全包扫一遍，文件改名也还能找到。
    private static func locate() -> URL? {
        if let url = Bundle.main.url(forResource: postScriptName, withExtension: "ttf") {
            return url
        }
        if let url = Bundle.main.url(forResource: postScriptName, withExtension: "ttf",
                                     subdirectory: "Resources/Fonts")
        {
            return url
        }
        return Bundle.main
            .urls(forResourcesWithExtension: "ttf", subdirectory: nil)?
            .first { $0.lastPathComponent.hasPrefix("PatrickHand") }
    }
}

// MARK: - 该用哪个字

/// 会随「手写体」开关变的那几处字。
///
/// **`hand` 是参数不是从单例里读的。** 从 `CloseCrabConfig.shared` 里读的话，
/// 调用它的视图如果没订阅那个 config，开关拨了字不会变 —— 而这种
/// 「改了没反应」的 bug 在 SwiftUI 里最难查，因为代码看上去完全正确。
/// 做成纯函数之后，依赖是显式的：谁调用谁负责订阅。
nonisolated enum CCType {
    /// 手写体的 x-height 比 SF 小一截，**同样点数下看着小一圈**。
    /// 不补这个系数的话方块底下那行名字会糊成一团。
    /// 1.22 是按 Patrick Hand 的 x-height 比例估的，真机上可以再调。
    static let handScale: CGFloat = 1.22

    /// 方块底下那行房间名。
    static func roomName(_ size: CGFloat, hand: Bool) -> Font {
        hand
            ? .custom(CCHandFont.postScriptName, size: size * handScale)
            : .system(size: size, weight: .medium, design: .rounded)
    }

    /// 方块中间那个字 —— 没设过自定义图标时显示的名字首字母。
    ///
    /// **手写体在这儿收益最大。** 一个 SF 的大写 "J" 和一个手写的 "J"，
    /// 后者自带笔锋和不对称，六个并排时一眼能分开。
    static func roomInitial(_ size: CGFloat, hand: Bool) -> Font {
        hand
            ? .custom(CCHandFont.postScriptName, size: size * handScale)
            : .system(size: size, weight: .semibold)
    }

    /// 左上角房间条上那个名字。
    static func roomBar(_ size: CGFloat, hand: Bool) -> Font {
        hand
            ? .custom(CCHandFont.postScriptName, size: size * handScale)
            : .system(size: size, weight: .medium)
    }
}
