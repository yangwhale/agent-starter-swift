import Foundation

/// 房间选择与方块状态的**纯逻辑**。
///
/// 单独拎出来只有一个理由：**这是这套界面里唯一能离线验证的部分。**
/// 开发机是 Linux、没有 Xcode，SwiftUI 和 LiveKit 那些一行都编不了；
/// 而这个文件只 import Foundation，可以用 Linux 上的 swiftc 真编真跑
/// （见仓库外的 `CCRoomSelectionTests.swift`）。
///
/// 所以规则尽量往这里塞：能写成纯函数的判断，就不要写在 View 里。
/// View 里写的东西，在真机跑之前没有任何人能说它对不对。
nonisolated public enum CCRoomSelection {
    /// 把一份「勾选了哪些房间」规范化成真正能用的名单。
    ///
    /// 两条不变量，**读和写都各过一遍**，不靠调用方自觉：
    ///
    /// 1. 只保留仍在服务端名单 `all` 里的。bot 下架之后勾选还留着的话，
    ///    界面会显示一个连不上的房间，而错误要到点连接那一刻才冒出来。
    /// 2. **`active` 永远在里面。** 对着一个没连上的 bot 说话是无意义状态，
    ///    与其在界面上拦，不如让它在数据层就构造不出来。
    ///
    /// 顺序跟随 `all`，**不跟随勾选先后** —— 否则顶部方块的位置会随着
    /// 勾来勾去乱跳，肌肉记忆全废。
    public static func normalize(all: [String], picked: [String], active: String) -> [String] {
        var keep = Set(picked
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { all.contains($0) })
        let activeName = active.trimmingCharacters(in: .whitespaces)
        if !activeName.isEmpty, all.contains(activeName) { keep.insert(activeName) }
        return all.filter { keep.contains($0) }
    }

    /// 勾 / 取消勾一个房间，返回新的名单。
    ///
    /// **当前说话的那个取消不掉** —— 直接原样返回，而不是弹提示。
    /// 想让它下线，先把话筒切给别人，那才是用户真正的意图。
    public static func toggle(_ name: String, in picked: [String],
                              all: [String], active: String) -> [String]
    {
        guard name != active else { return normalize(all: all, picked: picked, active: active) }
        let next = picked.contains(name) ? picked.filter { $0 != name } : picked + [name]
        return normalize(all: all, picked: next, active: active)
    }
}

/// 槽位该怎么增删排。**纯数据，不碰连接**，所以能离线测。
nonisolated public struct CCSlotPlan: Equatable, Sendable {
    /// 要新建连接的房间（按目标顺序）。
    public let toAdd: [String]
    /// 要断开并丢掉的房间。
    public let toRemove: [String]
    /// 最终顺序。
    public let order: [String]
    /// 话筒该对着谁。
    public let active: String
}

nonisolated public extension CCRoomSelection {
    /// 算出「现有槽位」到「想要的房间」之间该做哪些增删。
    ///
    /// 抽成纯函数的理由跟上面一样：槽位生命周期错了，症状是**房间悄悄断了**
    /// 或者**同一个房间连了两条**，两种都不会报错，只会表现成「它怎么不说话了」。
    /// 这种 bug 必须在能跑测试的地方挡住。
    ///
    /// ⚠️ **`want` 为空时什么都不做。** 空名单几乎总是「服务端列表还没拉到」
    /// 而不是「用户真的一个都不要」—— 照单执行会把正连着的全断掉，
    /// 然后界面空白，看着像 app 崩了。
    static func planSlots(current: [String], want: [String], active: String) -> CCSlotPlan {
        guard !want.isEmpty else {
            return CCSlotPlan(toAdd: [], toRemove: [], order: current, active: active)
        }
        return CCSlotPlan(
            toAdd: want.filter { !current.contains($0) },
            toRemove: current.filter { !want.contains($0) },
            order: want,
            active: want.contains(active) ? active : (want.first ?? "")
        )
    }
}

/// 一个方块外面那圈的状态。**互斥，按优先级取第一个命中的。**
///
/// 优先级不是随便定的 —— 同一时刻可能同时「被静音」且「在说话」
/// （它确实在出声，只是我听不见）。这时候该显示哪个？显示红色。
/// 因为「我听不见」是用户主动造成的、需要被提醒的状态；
/// 而「它在说话」此刻对用户没有任何可操作性。
nonisolated public enum CCTileRing: String, Equatable, Sendable {
    /// 还没连上（多房间连接层尚未落地时，非当前房间都是这个）。
    case pending
    /// 被我静音了 —— 连着，但它说什么我都听不见。
    case muted
    /// 正在出声。
    case speaking
    /// 在线、能说、此刻没说。
    case idle

    /// 从四个原始信号推出该画哪种圈。
    ///
    /// 参数全是布尔，**没有一个是「界面状态」** —— 这样才测得动。
    public static func derive(isConnected: Bool, isMuted: Bool, isSpeaking: Bool) -> CCTileRing {
        if !isConnected { return .pending }
        if isMuted { return .muted }
        if isSpeaking { return .speaking }
        return .idle
    }
}
