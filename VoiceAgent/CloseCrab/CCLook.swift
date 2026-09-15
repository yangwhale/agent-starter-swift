import Foundation

/// 外观相关的**纯逻辑**：天色怎么随时间走、背景选哪张、深浅色三档。
///
/// ## 为什么单独成文件
///
/// 跟 `CCRoomSelection.swift` 是同一个理由：这台开发机是 Linux，没有 Xcode，
/// SwiftUI 一行都编不了。只依赖 Foundation 的东西能在 Linux 的 swiftc 下
/// **真编真跑**，所以凡是能判对错的规则都往这里塞。
///
/// 写进 View 里的东西，在真机跑起来之前没有任何人能说它对不对 ——
/// 而 Chris build 一回不容易。
///
/// 对应测试：`Tests/CCLookTests.swift`。

// MARK: - 天色

/// 一天里的四段天色。
///
/// **四段不是三段也不是六段**：四段刚好对上「醒来 / 白天 / 下班 / 夜里」这四种
/// 真实场景，而这个 app 的使用高峰就是通勤那两头。再细分下去人是感觉不出来的，
/// 只会让背景一天换八次，变成打扰。
nonisolated enum CCSkyPhase: String, CaseIterable, Sendable {
    case dawn
    case day
    case dusk
    case night

    var label: String {
        switch self {
        case .dawn: "黎明"
        case .day: "白天"
        case .dusk: "黄昏"
        case .night: "夜里"
        }
    }
}

/// 背景用哪一张。`auto` 之外都是手动锁定。
nonisolated enum CCBackdropChoice: String, CaseIterable, Sendable, Identifiable {
    /// 跟着时钟走。默认。
    case auto
    // 手动锁定四段天色中的某一段。
    case dawn
    case day
    case dusk
    case night
    /// 轨道上看地平线。
    case orbit
    /// 抽象数据网格。
    case grid
    /// 不要图，退回纯极光（老样子）。
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "跟着时间走"
        case .dawn: "黎明"
        case .day: "白天"
        case .dusk: "黄昏"
        case .night: "深空"
        case .orbit: "轨道"
        case .grid: "数据网格"
        case .off: "不要背景图"
        }
    }
}

nonisolated enum CCSky {
    // MARK: 相位边界
    //
    // 单位是「当天的第几分钟」。**故意用固定时钟，不算真实日出日落。**
    //
    // 算真实日出需要定位权限，而这个 app 目前一个权限都不要。为了让背景早
    // 二十分钟变色去要一次定位授权，是拿一个用户看得见的代价换一个看不见的精度。
    // 香港一年里日出在 05:39–07:10 之间晃，日落在 17:39–19:12 之间晃 ——
    // 下面这几个边界取得比两头都宽，四季都落在合理区间内。
    //
    // 判断这条「良性的不精确」该不该修的标准是：**有没有人会因为它做错决定**。
    // 背景图早换晚换半小时，没有。

    /// 05:00
    static let dawnStart = 5 * 60
    /// 08:00
    static let dayStart = 8 * 60
    /// 16:30
    static let duskStart = 16 * 60 + 30
    /// 19:30
    static let nightStart = 19 * 60 + 30

    private static let boundaries = [dawnStart, dayStart, duskStart, nightStart]

    /// 把 (时, 分) 折算成当天的第几分钟，并强制落进 `[0, 1440)`。
    ///
    /// 取模那一步不是多余的：`Calendar` 正常只会给 0–23，但这个函数也被测试和
    /// 未来可能的时区换算调用。**越界输入不该返回一个看起来正常的错值** ——
    /// 折回去比崩掉好，比返回 `.night` 也好（那会把 bug 伪装成夜里）。
    static func minutes(hour: Int, minute: Int) -> Int {
        let raw = hour * 60 + minute
        let m = raw % (24 * 60)
        return m < 0 ? m + 24 * 60 : m
    }

    /// 此刻是哪一段天色。
    static func phase(hour: Int, minute: Int = 0) -> CCSkyPhase {
        switch minutes(hour: hour, minute: minute) {
        case dawnStart ..< dayStart: .dawn
        case dayStart ..< duskStart: .day
        case duskStart ..< nightStart: .dusk
        default: .night
        }
    }

    /// 距离下一次换天色还有多少秒。
    ///
    /// **有了这个就不用轮询。** 视图 sleep 这么久再醒一次就行 ——
    /// 定时器每分钟醒一次去比对「相位变了没有」，一天白醒 1436 次，
    /// 而它要等的事情一天只发生 4 次。
    ///
    /// 正好踩在边界上时返回的是**下一个**边界：踩上去那一刻相位已经切过去了。
    static func secondsUntilNextPhase(hour: Int, minute: Int, second: Int = 0) -> Int {
        let now = minutes(hour: hour, minute: minute) * 60 + min(max(second, 0), 59)
        for boundary in boundaries.map({ $0 * 60 }) where boundary > now {
            return boundary - now
        }
        // 今天没有下一个边界了（已经过了 19:30）→ 明天的第一个。
        return 24 * 3600 - now + dawnStart * 60
    }

    /// 最终要显示哪张图。`nil` ＝ 不要图。
    ///
    /// 资源名和枚举的 `rawValue` 是**同一个字符串**拼出来的，不是两份手写清单 ——
    /// 手写两份的下场是加一张图时改了一处忘了另一处，而症状是安静的空白背景。
    static func asset(for choice: CCBackdropChoice, hour: Int, minute: Int = 0) -> String? {
        switch choice {
        case .off:
            nil
        case .auto:
            "cc-bg-" + phase(hour: hour, minute: minute).rawValue
        default:
            "cc-bg-" + choice.rawValue
        }
    }
}

// MARK: - 深浅色

/// 深色模式三档。
///
/// 为什么要手动档：系统那档跟的是全局设置，而这个 app 的使用场景很极端 ——
/// 地铁里、夜里走路时、开着车。这几种情况下「现在想不想要一块亮屏」
/// 跟「系统现在是不是夜间模式」不是一回事。
///
/// （这条是 Primary: News in Depth 的 App Store 评价里，用户自己提的要求。）
nonisolated enum CCAppearance: String, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}
