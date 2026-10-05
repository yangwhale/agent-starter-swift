import Foundation

/// 断线之后「什么时候再连、还连不连」的规则。**只依赖 Foundation，离线可测。**
///
/// ## 为什么 app 自己要管重连
///
/// Chris 2026-10-05：网络一差连接就断，断了就再也不连 —— 有时 app 挂着没声，
/// 点进去也没声。查下来：
///
/// - LiveKit SDK（client-sdk-swift 2.17.0）自己只重试 **10 次**
///   （`ConnectOptions.reconnectAttempts = 10`，间隔 0.3 → 7 秒，合计约 40 秒）。
///   10 次都失败，房间就落到 `.disconnected`。
/// - 而 app 里调 `session.start()` 的只有两处：启动页那颗按钮、新勾一个房间。
///   **没有任何一处在断线之后再调一次。** 于是 SDK 一放弃，这条连接就永远断着。
///
/// ⇒ SDK 管「短抖动」，app 管「长断线」。两层各司其职，不重叠：
///   SDK 在重连时 `session.isConnected` 仍是 true（`.reconnecting` 也算连着），
///   app 这层只在它彻底变成 false 之后才接手。
///
/// ## 规则
///
/// - **只要用户没主动挂断，就一直试，不设上限。** 设上限＝把今天这个 bug 换个时长再犯一次。
/// - 间隔指数退避，封顶 30 秒：网络刚恢复时别等太久，长时间没网时别白耗电。
/// - 回前台、网络恢复这两个时刻**立刻试一次**，不等退避 —— 那正是最可能连上的时候。
public enum CCReconnectPolicy {
    /// 第 n 次（从 0 起）重试前等多少秒。最后一档之后一直用最后一档。
    public static let delays: [Double] = [1, 2, 4, 8, 15, 30]

    public static func delay(attempt: Int) -> Double {
        guard attempt > 0 else { return delays[0] }
        return delays[min(attempt, delays.count - 1)]
    }

    /// 前几次重试**不亮红条**，只显示一行安静的「正在重连」。
    ///
    /// Chris 2026-10-05 截图：jarvis 那边正好在重启，app 一连就超时，屏幕上挂一条
    /// 红色「jarvis 连不上」—— 而 app 其实正在后台自己重试，几秒后就会好。
    /// 红条只该留给「试了一阵还不行、需要人看一眼」的情况。
    /// 前 4 次的等待合计 1+2+4+8 = 15 秒（再加每次连接本身的超时），够吃掉一次 bot 重启。
    public static let quietAttempts = 4

    /// 已经失败 `failures` 次（从 0 起）时，界面该不该亮红条。
    public static func showsError(failures: Int) -> Bool {
        failures >= quietAttempts
    }

    /// 该不该再试一次。
    ///
    /// - `wantConnected`：用户的意图 —— 按过「开始」且没按「挂断」。
    /// - `isConnected`：`session.isConnected`，SDK 自己在重连时也是 true。
    /// - `inFlight`：这个房间已经有一次连接在路上（启动页、勾选、或上一轮重试）。
    public static func shouldRetry(wantConnected: Bool, isConnected: Bool, inFlight: Bool) -> Bool {
        wantConnected && !isConnected && !inFlight
    }
}
