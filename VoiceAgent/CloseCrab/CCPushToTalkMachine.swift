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
/// ## 触发方式
///
/// 默认用**右 Option 单独按住**（keyCode 61）。理由：
/// - 不跟任何系统/应用快捷键冲突（右 Option 单独按下在 macOS 里没有默认行为）
/// - 修饰键没有"按键重复"，天然适合按住类交互
/// - 单手可达，不用记组合
public nonisolated struct CCPushToTalkMachine: Sendable {
    /// 右 Option 的 keyCode。左 Option 是 58，我们只认右边 ——
    /// 左 Option 参与太多组合键（⌥←、⌥删除…），拿它做 PTT 会误触发。
    public static let rightOptionKeyCode: UInt16 = 61

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
        guard keyCode == Self.rightOptionKeyCode else { return .ignore }
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
