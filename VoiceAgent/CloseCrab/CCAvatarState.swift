import Foundation

/// 跟服务端约定的三个属性键。**改一个字母两边就对不上，而且两边都不报错** ——
/// 服务端读不到只会按缺省当「没要」，现象是「开关拨了没反应」。
/// 对面在 `closecrab/voice/avatar_policy.py` 的 `ATTR_*`。
///
/// 放在这个 Foundation-only 文件里有两个理由：
///
/// 1. 它是**线上契约**，该跟判定逻辑待在一起，而不是藏在某个 SwiftUI 对象里。
/// 2. 它得能从 `nonisolated` 的地方读 —— 收状态那个 delegate 回调必须是
///    `nonisolated`（`RoomDelegate` 是 `@objc` + `Sendable`）。
///
/// ## ⚠️ 每个 `static let` 都要单独标 `nonisolated`
///
/// 这个工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// **所有类型默认都是 MainActor-isolated，包括这个裸 enum**。
/// 不标的话，三个纯字符串常量照样被隔离，`nonisolated` 的回调里读不到：
///
///     main actor-isolated static property 'state'
///     can not be referenced from a nonisolated context
///
/// 隔离按**声明位置**算，跟内容有没有可变状态无关 —— 这一条很反直觉：
/// 一个 `let String` 读一下怎么会不安全？但编译器不看这个。
///
/// 第一次搬家时以为「搬出 @MainActor 类」就够了 —— 不够，默认隔离照样罩着。
public enum CCAvatarAttr {
    /// 客户端写：用户那个开关。
    public nonisolated static let want = "cc.avatar.want"
    /// 客户端写：现在看得见吗（已在客户端侧去抖）。
    public nonisolated static let visible = "cc.client.visible"
    /// **服务端写**，回报最终状态。全房共享一份，不是「你的」状态。
    public nonisolated static let state = "cc.avatar.state"
}

/// 服务端回报的数字人状态。只依赖 Foundation，所以能离线测。
///
/// ## 这是「网关这一路的状态」，不是「你的状态」
///
/// 数字人是**一条视频轨，全房共享** —— LiveKit 里没有「只发给某个人」这回事。
/// 所以服务端只能给出一个答案，它写在自己那个 participant 上，全房都读到同一份。
///
/// 后果：**屋里别人开着、你关着的时候，你也会收到 `on`。** 这是正常的，
/// 不是 bug。客户端因此**不能**把这个值当成唯一判据 —— 判断规则见
/// `shouldSurfaceProblem(userWants:)`。
public enum CCAvatarServerState: String, Sendable {
    case on
    case off
    /// 有人要，但他看不见（后台/锁屏），所以先不生成。回前台会自己变回 `on`。
    case hidden
    /// 有人要、也看得见，但服务端给不了（网关挂了 / 8 路槽位占满）。
    case unavailable
    /// 没收到过、或者收到一个不认识的值。
    ///
    /// 单独一档而不是并进 `off`：两者要让用户看到的东西不一样。
    /// `off` 是「确实关着」，`unknown` 是「还没消息」——
    /// 把后者显示成前者，会在服务端其实没回话时假装一切正常。
    case unknown

    /// 解析属性里的字符串。**认不出来一律 `unknown`，不抛不崩。**
    ///
    /// 服务端哪天多加一个状态（比如降级到低帧率），老客户端会走到这里。
    /// 让它安静地变成 `unknown` 比崩掉强。
    public static func parse(_ raw: String?) -> CCAvatarServerState {
        guard let raw else { return .unknown }
        return CCAvatarServerState(
            rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ) ?? .unknown
    }

    /// 要不要在界面上告诉用户「数字人这会儿没有」。
    ///
    /// **两个条件都要成立**：
    ///
    /// 1. 用户自己确实开着这个开关 —— 他没要的东西，不该为它道歉；
    ///    而且房间状态是全房共享的，别人的 `unavailable` 跟他无关。
    /// 2. 服务端说的是 `unavailable`。
    ///
    /// `hidden` 特意不报：那说明 app 在后台，屏幕上本来就没人看。
    /// 报了也是发给空气，回前台时它已经自己变回 `on` 了。
    public func shouldSurfaceProblem(userWants: Bool) -> Bool {
        userWants && self == .unavailable
    }


    /// 给用户看的一句话。**只在 `shouldSurfaceProblem` 为真时才用得上**，
    /// 其余状态不该出现在界面上。
    public var problemText: String {
        "Avatar 这会儿用不了（服务没响应，或者并发满了），先只出声。"
    }
}
