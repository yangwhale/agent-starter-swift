import Foundation

/// 「减弱动态效果」打开时，一条动画该怎么处理。
///
/// **单独一个文件、只 import Foundation，是为了能离线测。**
/// 这台开发机没有 Xcode，写进 View 里的东西在真机跑起来之前没人能说它对不对；
/// 而这个判断恰恰属于**错了也看不出来**的那一类 —— 它只在用户打开了
/// 辅助功能里那个开关时才生效，日常开发和演示中永远走不到。
/// 把它从 `CCTheme` 的 modifier 里抠出来变成纯函数，就能拿真值表钉死。
///
/// 语义与取舍见 `CCTheme.swift` 里 `CCReduceMotion` 的文档注释。
public enum CCMotionResolution: Equatable, Sendable {
    /// 完全不动。给纯装饰的无限循环动画（转圈、流光）。
    ///
    /// ⚠️ 叫 `still` 不叫 `none`：跟 `Optional.none` 同名是 Swift 里一类
    /// 经典歧义源 —— 在可选上下文里编译器会挑错边，而且报的警告很难读。
    case still
    /// 退化成淡出。给位移/缩放/弹簧这类状态切换 ——
    /// **不能直接变 `still`**，否则状态切换成硬跳，看着像界面卡了。
    case fade
    /// 原样使用调用方给的动画。
    case asRequested
}

public enum CCMotionPolicy {
    /// - Parameters:
    ///   - reduceMotion: 系统的「减弱动态效果」是否打开。
    ///   - decorative: 这条动画是不是**纯装饰**（不承载任何信息）。
    public static func resolve(reduceMotion: Bool, decorative: Bool) -> CCMotionResolution {
        // 没开开关就什么都不管 —— 这一条要放在最前面。
        // 写成「先看 decorative」的话，装饰性动画在开关关着时也会被降级，
        // 等于所有人都看不到转圈了。
        guard reduceMotion else { return .asRequested }
        return decorative ? .still : .fade
    }
}
