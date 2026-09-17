import Foundation

/// 按住说话的**纯判定逻辑** —— 把键盘事件翻译成「开始说话 / 结束说话」。
///
/// ## 为什么要单独抽出来
///
/// 真正的全局热键要靠 AppKit 的 `NSEvent` 监听，那玩意儿在 Linux 上不存在、
/// 在 CI 里也跑不了。而这里面**最容易错的恰恰不是监听本身，是状态判定**：
///
/// - 按住不放时系统会持续重复投递事件 —— 不能每次都当成"又按了一次"
/// - `.flagsChanged` 只告诉你"修饰键集合变了"，**不告诉你是按下还是抬起**，
///   得自己跟上一次比
/// - 全局监听拿不到焦点信息，切走 app 时可能永远等不到抬起事件 ——
///   **会卡在"一直在说话"**，这是最难受的失败：麦克风一直开着而你不知道
///
/// 这些都是纯状态机问题，抽出来就能离线测。AppKit 那层只负责把事件喂进来。
///
/// ## 触发键可配
///
/// 默认右 Option，但**必须可配** —— 每个人的键盘习惯不一样，
/// 写死一个键等于替用户做了个他没同意的决定。见 `CCPushToTalkKey`。

/// 能用来做按住说话的修饰键。
///
/// 只收**修饰键**，不收普通字母键：修饰键没有"按键重复"，天然适合按住类交互；
/// 普通键按住时系统会连发，还会跟输入法、快捷键打架。
public nonisolated enum CCPushToTalkKey: String, CaseIterable, Sendable, Identifiable {
    case rightOption, leftOption
    case rightCommand, rightControl, rightShift
    case fn
    case off

    public var id: String { rawValue }

    /// macOS 的物理 keyCode。左右同名键的 code 不同 —— 这正是能区分左右的原因。
    public var keyCode: UInt16? {
        switch self {
        case .rightOption: 61
        case .leftOption: 58
        case .rightCommand: 54
        case .rightControl: 62
        case .rightShift: 60
        case .fn: 63
        case .off: nil
        }
    }

    /// 这个键对应哪一位修饰位。AppKit 那层据此判断"它现在是按下的吗"。
    public var flag: CCModifierFlag? {
        switch self {
        case .rightOption, .leftOption: .option
        case .rightCommand: .command
        case .rightControl: .control
        case .rightShift: .shift
        case .fn: .function
        case .off: nil
        }
    }

    public var label: String {
        switch self {
        case .rightOption: "右 Option ⌥"
        case .leftOption: "左 Option ⌥"
        case .rightCommand: "右 Command ⌘"
        case .rightControl: "右 Control ⌃"
        case .rightShift: "右 Shift ⇧"
        case .fn: "Fn / 地球键"
        case .off: "关闭（只用窗口内空格）"
        }
    }

    /// ⚠️ 左侧那几个键参与大量组合（⌥← ⌘C ⌃A …），选了容易误触发。
    /// 界面上要把这句提示出来，别让人选完才发现。
    public var warning: String? {
        switch self {
        case .leftOption: "左 Option 参与很多组合键（⌥← 等），容易误触发"
        case .rightCommand: "⌘ 组合极多，只在确定不冲突时用"
        case .fn: "部分键盘的 Fn 不产生事件，选了可能完全没反应"
        default: nil
        }
    }
}

/// 修饰位。**不直接用 `NSEvent.ModifierFlags`** —— 那是 AppKit 的类型，
/// 带进来这个文件就没法在 Linux 上测了。AppKit 那层负责翻译。
public nonisolated enum CCModifierFlag: Sendable {
    case option, command, control, shift, function
}

public nonisolated struct CCPushToTalkMachine: Sendable {
    /// 兼容旧调用点。新代码用 `CCPushToTalkKey.rightOption.keyCode`。
    public static let rightOptionKeyCode: UInt16 = 61

    /// 当前触发键。改了要立刻收尾 —— 否则按着旧键的手会永远等不到抬起。
    public var key: CCPushToTalkKey = .rightOption {
        didSet {
            guard key != oldValue else { return }
            isHolding = false
            lastOptionDown = false
        }
    }

    public enum Action: Equatable, Sendable {
        case begin
        case end
        case ignore
    }

    /// 当前是否正按着。外部只读，判定全在这里面。
    public private(set) var isHolding = false

    /// 上一次看到的「右 Option 是否按下」。`.flagsChanged` 不区分按下/抬起，
    /// 只能靠跟上一次比才知道方向。
    private var lastOptionDown = false

    public init() {}

    /// 喂一个 `.flagsChanged` 事件。
    ///
    /// - Parameters:
    ///   - keyCode: 事件的 keyCode。只有右 Option 会被理会。
    ///   - optionPressed: 事件修饰位里 Option 是否处于按下状态。
    public mutating func onFlagsChanged(keyCode: UInt16, optionPressed: Bool) -> Action {
        guard let want = key.keyCode, keyCode == want else { return .ignore }
        defer { lastOptionDown = optionPressed }

        if optionPressed, !lastOptionDown, !isHolding {
            isHolding = true
            return .begin
        }
        if !optionPressed, lastOptionDown, isHolding {
            isHolding = false
            return .end
        }
        // 同一状态重复投递（系统会这么干）→ 什么都不做
        return .ignore
    }

    /// app 失去焦点、会话断开、系统休眠 —— 任何"可能再也收不到抬起事件"的时刻
    /// 都必须调这个。
    ///
    /// ⚠️ **不调的后果是麦克风一直开着**，而界面上你只看到"它好像在听"，
    /// 不会有任何报错。全局监听最典型的坑就在这儿：按下的时候 app 在前台，
    /// 按住的过程中切走了，抬起事件被别人吃掉，于是永远等不到 `.end`。
    public mutating func forceRelease() -> Action {
        guard isHolding else { return .ignore }
        isHolding = false
        // ⛔ **不要在这里清 `lastOptionDown`。**
        //
        // 第一版清了，于是：切走 app → forceRelease → 用户手指还按着 →
        // 系统再投一次「Option 仍按下」→ 因为 lastOptionDown 被清成 false，
        // 这个事件长得就像一次全新按下 → **人在别的 app 里，麦克风自己又开了**。
        // 正好是这个状态机存在的理由，被它自己制造了出来。
        //
        // 保留 lastOptionDown 就够了：下一个「仍按下」事件会被
        // `!lastOptionDown` 挡住，直到用户真的松开一次。
        // （中间我加过一个额外的 suppressedUntilRelease 闸，后来拆了 ——
        //   它不改变任何行为，反而把上面那条判断挡成不可达，
        //   导致变异测试对它失灵。）
        return .end
    }

    /// 窗口聚焦时的空格键路径。全局热键要辅助功能权限，而**空格这条不需要** ——
    /// 没授权时它就是唯一能用的按住说话方式，所以不能只做全局那条。
    ///
    /// - Parameter isTextInputActive: 光标在输入框里时必须让位，
    ///   否则用户打字打不出空格。
    public mutating func onSpace(down: Bool, isTextInputActive: Bool) -> Action {
        if isTextInputActive {
            // 焦点跑进输入框时如果正按着，得收尾 —— 否则同样会卡在"一直在说话"
            return forceRelease()
        }
        if down, !isHolding {
            isHolding = true
            return .begin
        }
        if !down, isHolding {
            isHolding = false
            return .end
        }
        return .ignore   // 按住空格时系统的按键重复
    }
}
