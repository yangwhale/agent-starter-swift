import Foundation

/// 头像右下角那颗在线状态小圆点的规则。**只依赖 Foundation，离线可测。**
///
/// Chris 2026-10-05：「像 Google Chat 一样，头像上一个小圆点，在线绿、没连上灰，
/// 还有红、黄这些状态你研究研究。」
///
/// ## 跟方块外圈分工
///
/// 外圈（`CCTileRing`）管**声音**：在说话、被静音、空闲。
/// 这颗点管**连接健康**：连没连上、对方在不在、网络好不好。
/// 两件事各占一个视觉位置，不抢同一个颜色通道。
///
/// ## 五种状态，按优先级取第一个命中的
///
/// | 点 | 含义 | 什么信号 |
/// |---|---|---|
/// | 灰 `off` | 没在连 | 没按「开始」或已挂断 |
/// | 红 `retrying` | 该连着却断了，等下一次重试 | 房间断开，但用户意图是连着（重连循环在跑） |
/// | 黄 `connecting` | 正在连 / SDK 正在自己重连 | `.connecting` / `.reconnecting` |
/// | 橙 `degraded` | 连着但有毛病 | bot 不在房间里，或本机网络质量差 / 丢失 |
/// | 绿 `online` | 一切正常 | 连着、bot 在、网络好 |
///
/// 网络质量来自 LiveKit 服务器给每个参与者打的分（`ConnectionQuality`：
/// excellent / good / poor / lost），取**本机这一端**的 —— 「我这边网差不差」
/// 才是用户能动手处理的（换 Wi-Fi、走到信号好的地方）。
nonisolated public enum CCPresencePhase: Sendable, Equatable {
    case disconnected, connecting, reconnecting, connected
}

nonisolated public enum CCPresenceQuality: Sendable, Equatable {
    case unknown, lost, poor, good, excellent
}

nonisolated public enum CCPresenceDot: String, Sendable, Equatable {
    case off, retrying, connecting, degraded, online

    public static func derive(
        wantConnected: Bool,
        phase: CCPresencePhase,
        botPresent: Bool,
        quality: CCPresenceQuality
    ) -> CCPresenceDot {
        switch phase {
        case .connecting, .reconnecting:
            return .connecting
        case .connected:
            // 刚连上时质量还没打分（unknown），不算差 —— 否则每次连接都先闪一下橙。
            if !botPresent || quality == .poor || quality == .lost { return .degraded }
            return .online
        case .disconnected:
            return wantConnected ? .retrying : .off
        }
    }

    /// 读屏念的那句。颜色信息不能只靠颜色（色觉障碍用户看到的是灰点）。
    public var spoken: String {
        switch self {
        case .off: "未连接"
        case .retrying: "已断开，正在重试"
        case .connecting: "正在连接"
        case .degraded: "已连接，但有问题"
        case .online: "在线"
        }
    }
}
