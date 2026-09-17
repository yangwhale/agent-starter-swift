import Foundation

/// 「用户现在看得见画面吗」—— 一个只有一条规则的状态机：**关要慢，开要快**。
///
/// 只依赖 Foundation，时间从外面传进来（不碰 `Date()`），所以能在
/// 命令行上穷举跑完，不用起模拟器。跟 `CCMotionPolicy` 同一套思路。
///
/// ## 为什么不能直接把 scenePhase 当答案
///
/// iOS 的 `scenePhase` 有三态，而 `.inactive` **极其常见且极其短暂**：
/// 拉下通知中心、进 App 切换器、来电横幅、下拉搜索，都会进这个态，
/// 一两秒后就回来。
///
/// 数字人起一次不便宜（实测首帧 1.26 秒，之前还要向网关抢一路槽位）。
/// 扫一眼通知就把它掐掉再重起，比全程不掐还难受 —— 用户看到的是画面
/// 莫名其妙闪一下。
///
/// 所以：**进后台要等一会儿才认，回前台立刻认。**
/// 不对称是故意的 —— 两个方向的代价根本不一样。误判成「看不见」会让
/// 正在看的人画面断掉，误判成「看得见」只是多渲染几秒。
///
/// ## 为什么 `.inactive` 和 `.background` 一视同仁
///
/// 本来可以给 `.background` 配一个更短的宽限（它比 `.inactive` 确定得多）。
/// 没这么做是因为**宽限期本身已经把两者区分开了**：扫一眼通知是两秒，
/// 远小于宽限；真的切走则会一直停在后台，宽限一到自然生效。
/// 两个计时器换不来行为上的差别，只多一份要维护的状态。
///
/// ## 前提：app 在后台不能被挂起
///
/// 宽限到期要靠定时器触发，而被挂起的 app 不跑定时器。这里成立是因为
/// `Info.plist` 里开了 `UIBackgroundModes: audio` —— 语音 app 本来就得
/// 在后台继续出声。**哪天那个后台模式被摘掉，这套去抖会静默失效**：
/// 进后台再也不上报，服务端一直以为你在看，白占一路槽位。
public enum CCScenePhaseKind: Sendable {
    case active
    case inactive
    case background
}

public struct CCVisibilityPolicy: Sendable {
    /// 进后台之后等多久才认「看不见了」。
    ///
    /// 8 秒是这么定的：要明显长过「扫一眼通知再回来」（1–3 秒），
    /// 又要明显短过「用户真切走了之后还在白烧 GPU」能忍的时间。
    /// 中间这一段很宽，不用纠结具体取值。
    public static let backgroundGrace: TimeInterval = 8

    /// 现在认为看得见吗。**初值是 true** —— app 起来的第一刻就是前台。
    public private(set) var isVisible = true

    /// 从什么时候开始不在前台了。`nil` = 现在就在前台。
    private var awaySince: TimeInterval?

    public init() {}

    /// 喂一次 scenePhase。返回**可见性有没有变**，变了才需要上报。
    ///
    /// - Parameter now: 单调时钟的读数（秒）。由调用方提供，方便测试。
    @discardableResult
    public mutating func update(phase: CCScenePhaseKind, now: TimeInterval) -> Bool {
        let before = isVisible
        switch phase {
        case .active:
            // 立刻恢复，不等任何东西。宽限只管「关」这个方向。
            awaySince = nil
            isVisible = true
        case .inactive, .background:
            if awaySince == nil { awaySince = now }
            // **不在这里判超时**。这个函数只在 scenePhase 变化时被调用，
            // 而「在后台待够 8 秒」期间根本没有事件 —— 真正让它翻过去的是
            // 下面 `tick(now:)`，由调用方按 `deadline` 排一个定时器。
        }
        return isVisible != before
    }

    /// 宽限到了没有。定时器醒来时调，返回**可见性有没有变**。
    @discardableResult
    public mutating func tick(now: TimeInterval) -> Bool {
        guard let since = awaySince, isVisible else { return false }
        guard now - since >= Self.backgroundGrace else { return false }
        isVisible = false
        return true
    }

    /// 下次该在什么时候醒来重判；`nil` = 不用排定时器。
    ///
    /// 已经判成看不见之后返回 `nil` —— 不然会排出一串永远什么都不做的定时器。
    public func deadline(from now: TimeInterval) -> TimeInterval? {
        guard let since = awaySince, isVisible else { return nil }
        return max(0, since + Self.backgroundGrace - now)
    }
}
