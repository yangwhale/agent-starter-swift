import LiveKit
import SwiftUI

/// 网络读数 —— **抖动缓冲现在有多深、丢了多少包**。
///
/// ## 为什么要它
///
/// 地铁里会短暂丢一串 UDP 包，听感是吞字。想治它得先知道是哪种情况：
///
/// - 缓冲根本没涨上去（自适应算法反应慢）→ 该在服务端抬高最小播放延迟
/// - 涨上去了还是吞 → 那就不是缓冲的问题，是整段断流，加深缓冲也没用
///
/// **这两种在耳朵里一模一样**，只能靠数字分辨。所以先做读数，再决定要不要
/// 动服务端那个全局配置 —— 不然就是拿一个猜测去改一个影响所有房间的设置。
///
/// ## 能读不能写
///
/// ⚠️ 客户端**没有**调节缓冲深度的接口。翻过 SDK：包装 receiver 的那层是
/// `internal`，统计里的 `jitterBufferMinimumDelay` 是只读观测值。
/// 唯一的旋钮是服务端 `room.playout_delay`（全局）或建房时的房间配置，
/// 而我们的房间 `empty_timeout` 设成了十年、永不消失，房间配置那条也够不着。
///
/// 所以这个组件**只显示，不控制**。别指望在这儿加个滑杆。
///
/// ## 数字怎么来的
///
/// `jitterBufferDelay / jitterBufferEmittedCount` 是 WebRTC 统计的标准算法：
/// 前者是累计延迟秒数，后者是累计吐出的样本数，**相除才是当前平均驻留时间**。
/// 直接读 `jitterBufferDelay` 会得到一个一直在涨的累计值，那是最常见的误读。
@MainActor
final class CCNetStats: ObservableObject {
    struct Snapshot: Equatable {
        /// 当前缓冲平均深度，毫秒。
        var bufferMs: Double = 0
        /// 目标深度（自适应算法想要的），毫秒。
        var targetMs: Double = 0
        /// 丢包率，0–1。
        var loss: Double = 0
        var hasData = false
    }

    @Published private(set) var snap = Snapshot()

    private var timer: Task<Void, Never>?
    /// 存 `Track` 不存 `AudioTrack`：后者是协议，**没有 class 约束就不能 weak**。
    /// 转换在 `watch` 里做一次，省得每次采样都转。
    private weak var track: Track?

    /// 开始盯一条远端音轨。换房间时重新调一次。
    func watch(_ track: AudioTrack?) {
        stop()
        guard let t = track as? Track else { return }
        self.track = t
        Task { await t.set(reportStatistics: true) }
        // 一秒一次。再密没意义 —— WebRTC 的统计本身就是约 1s 一个快照，
        // 而且这是给人看的读数，不是给算法用的。
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        guard let t = track,
              let inbound = t.statistics?.inboundRtpStream.first
        else { snap = Snapshot(); return }

        var s = Snapshot()
        s.hasData = true
        if let delay = inbound.jitterBufferDelay,
           let emitted = inbound.jitterBufferEmittedCount, emitted > 0
        {
            s.bufferMs = delay / Double(emitted) * 1000
        }
        if let target = inbound.jitterBufferTargetDelay,
           let emitted = inbound.jitterBufferEmittedCount, emitted > 0
        {
            s.targetMs = target / Double(emitted) * 1000
        }
        if let lost = inbound.packetsLost, let got = inbound.packetsReceived {
            let total = Double(got) + Double(max(lost, 0))
            if total > 0 { s.loss = Double(max(lost, 0)) / total }
        }
        snap = s
    }

    // 没有 deinit：`deinit` 是 nonisolated 的，在里面碰 `timer` 这个
    // MainActor 隔离的属性，Swift 6 下直接编译不过。
    // 回收靠两条：Task 捕获的是 `[weak self]`，以及视图 `onDisappear` 调 stop()。
}

/// 控制栏旁边那一小条读数。**默认不显示**，在设置里开。
///
/// 平时它是噪音 —— 一个正常人不需要随时看着丢包率。只有在「地铁上又吞字了」
/// 那一刻它才有价值，所以做成开关，别常驻。
struct CCNetReadout: View {
    @EnvironmentObject private var rooms: CCRooms
    @StateObject private var stats = CCNetStats()

    var body: some View {
        Group {
            if stats.snap.hasData {
                HStack(spacing: 8) {
                    pill("缓冲", String(format: "%.0f", stats.snap.bufferMs), "ms",
                         tint: bufferTint)
                    pill("目标", String(format: "%.0f", stats.snap.targetMs), "ms",
                         tint: .fg3)
                    pill("丢包", String(format: "%.1f", stats.snap.loss * 100), "%",
                         tint: stats.snap.loss > 0.03 ? .fgSerious : .fg3)
                }
            } else {
                Text(verbatim: "等首帧音频…")
                    .font(CC.Font.caption)
                    .foregroundStyle(.fg3)
            }
        }
        // 换房间要重新盯 —— 统计是**每条音轨**各自的，不换等于一直看着旧房间。
        //
        // `onChange(initial: true)` 而不是 `task(id:)`：`watch` 是同步的
        // MainActor 方法，而 `task` 的闭包是 `@Sendable`、不保证继承主 actor。
        // `onChange` 收普通同步闭包，在这个工程（默认 MainActor 隔离）下必然继承。
        // `initial: true` 补上「第一次出现时也跑一次」，语义和 task 一样。
        .onChange(of: rooms.activeName, initial: true) { _, _ in
            stats.watch(rooms.active?.agentAudioTrack)
        }
        .onDisappear { stats.stop() }
    }

    /// 缓冲深度的颜色只是个粗判：
    /// 200ms 以下＝自适应算法认为网络很好；超过 600ms 说明它已经在拼命兜底了。
    private var bufferTint: Color {
        switch stats.snap.bufferMs {
        case ..<200: .fgSuccess
        case ..<600: .fg2
        default: .fgSerious
        }
    }

    private func pill(_ label: String, _ value: String, _ unit: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: label)
                .font(CC.Font.caption)
                .foregroundStyle(.fg3)
            // 等宽数字 —— 不然每次刷新宽度都在跳，整条读数像在抖。
            Text(verbatim: value)
                .font(CC.Font.numeric)
                .foregroundStyle(tint)
            Text(verbatim: unit)
                .font(CC.Font.caption)
                .foregroundStyle(.fg3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.bg2.opacity(0.6)))
    }
}
