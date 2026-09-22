import Observation
import LiveKit
import SwiftUI

/// 诊断页的数据源 —— 把 WebRTC 统计里能拿到的都抓齐。
///
/// ## 两条轨都要采
///
/// 统计是**按轨**挂的，收和发是两套：
///
/// - **agent 的远端音轨** → 收下行那一组（缓冲、丢包、吞字），以及 ICE/传输层
/// - **自己的麦克风轨** → 上行那一组（对端看到的丢包、编码码率、发送延迟）
///
/// 只采一条会缺一半，而缺的那一半恰好是排查「他听不见我」时要看的。
///
/// ## 累计值必须自己求差
///
/// WebRTC 统计里绝大多数计数器是**单调累加**的。直接显示 `concealmentEvents`
/// 会看到一个从连接开始一直涨的数，看不出「刚才那一下卡是不是又吞了」。
/// 所以这里留了上一帧快照，算出每秒增量 —— **速率才是能用来判断的量**。
///
/// 同理 `jitterBufferDelay` 是累计秒数，要除以 `jitterBufferEmittedCount`
/// 才是当前平均驻留时间。这是最常见的误读。
@MainActor
@Observable
final class CCDiagnostics {
    /// 一行读数：标题、值、可选的提示。
    struct Row: Identifiable {
        let id = UUID()
        let name: String
        let value: String
        var hint: String? = nil
        var alert: Bool = false
    }

    struct Group: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let rows: [Row]
    }

    private(set) var groups: [Group] = []
    private(set) var updatedAt: String = "—"

    private var timer: Task<Void, Never>?
    private weak var remote: Track?
    private weak var local: Track?

    /// 上一帧的累计计数，用来求每秒增量。
    private var prev: [String: Double] = [:]

    func start(remote remoteTrack: AudioTrack?, local localTrack: AudioTrack?) {
        stop()
        // ⚠️ 不要写 `as? Track`：`AudioTrack` 本身就是 `Track & AudioTrackProtocol`，
        // 向下转换是多余的，编译器会报 conditional downcast ... is equivalent to
        // an implicit conversion。直接赋值即可（可选性自动带过去）。
        self.remote = remoteTrack
        self.local = localTrack
        for t in [self.remote, self.local].compactMap({ $0 }) {
            Task { await t.set(reportStatistics: true) }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                // `guard let self`，不是 `self?.sample()` ——
                // 后者在对象没了之后每秒空转到天荒地老。
                // **弱引用防的是泄漏对象，不防泄漏循环。**
                guard let self else { return }
                sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        // ⚠️ **必须把统计也关掉。** `start` 里那句
        // `set(reportStatistics: true)` 会让 WebRTC 持续计算统计，
        // 而它**不随定时器停止** —— 诊断页开过一次，那份计算就一直挂着，
        // 关掉窗口也不会停。
        //
        // 跟 `CCNetReadout.stop()` 同一个坑、同一天（2026-09-22）发现的：
        // **「开了一个开关」和「起了一个定时器」是两件事，
        //   收尾时容易只收自己起的那个。**
        for t in [remote, local].compactMap({ $0 }) {
            Task { await t.set(reportStatistics: false) }
        }
        timer?.cancel()
        timer = nil
        prev.removeAll()
    }

    // MARK: - 采样

    private func sample() {
        let rs = remote?.statistics
        let ls = local?.statistics
        let inb = rs?.inboundRtpStream.first
        // ICE / 传输层两条轨看到的是同一份，哪条有用哪条。
        let pair = (rs?.iceCandidatePair ?? []).first { $0.nominated == true }
            ?? (rs?.iceCandidatePair ?? []).first
            ?? (ls?.iceCandidatePair ?? []).first
        let remoteCand = rs?.remoteIceCandidate ?? ls?.remoteIceCandidate
        let localCand = rs?.localIceCandidate ?? ls?.localIceCandidate
        let transport = rs?.transportStats ?? ls?.transportStats
        let outb = ls?.outboundRtpStream.first
        let remIn = ls?.remoteInboundRtpStream.first
        let codec = (rs?.codec ?? []).first

        var g: [Group] = []

        // ── A 链路 ────────────────────────────────────────────────────
        g.append(Group(title: "链路", subtitle: "网络本身好不好", rows: [
            Row(name: "往返延迟 RTT",
                value: ms(pair?.currentRoundTripTime.map { $0 * 1000 }),
                hint: "一个来回。150ms 以内基本感觉不到",
                alert: (pair?.currentRoundTripTime ?? 0) > 0.3),
            Row(name: "传输协议",
                value: transportDesc(localCand, remoteCand),
                hint: "UDP 还是 TCP —— 这是实测，不是推测"),
            Row(name: "候选类型",
                value: "\(desc(localCand?.candidateType)) → \(desc(remoteCand?.candidateType))"),
            Row(name: "下行可用带宽", value: kbps(pair?.availableIncomingBitrate)),
            Row(name: "上行可用带宽", value: kbps(pair?.availableOutgoingBitrate)),
            Row(name: "候选对切换次数",
                value: int(transport?.selectedCandidatePairChanges),
                hint: "地铁里换基站会涨。涨一次≈网络抖了一次",
                alert: (transport?.selectedCandidatePairChanges ?? 0) > 2),
            Row(name: "ICE / DTLS 状态",
                value: "\(desc(transport?.iceState)) / \(desc(transport?.dtlsState))"),
        ]))

        // ── B 听感（收下行）───────────────────────────────────────────
        let emitted = Double(inb?.jitterBufferEmittedCount ?? 0)
        let bufMs = emitted > 0 ? (inb?.jitterBufferDelay ?? 0) / emitted * 1000 : 0
        let tgtMs = emitted > 0 ? (inb?.jitterBufferTargetDelay ?? 0) / emitted * 1000 : 0
        let got = Double(inb?.packetsReceived ?? 0)
        let lost = Double(max(inb?.packetsLost ?? 0, 0))
        let lossPct = (got + lost) > 0 ? lost / (got + lost) * 100 : 0
        let totalSamples = Double(inb?.totalSamplesReceived ?? 0)
        let concealed = Double(inb?.concealedSamples ?? 0)
        let concealRate = rate("conceal", Double(inb?.concealmentEvents ?? 0))
        let discardRate = rate("discard", Double(inb?.packetsDiscarded ?? 0))

        g.append(Group(title: "听感 · 收下行", subtitle: "耳朵实际被坑了多少", rows: [
            Row(name: "缓冲深度", value: ms(bufMs),
                hint: "音频在缓冲里平均待多久", alert: bufMs > 600),
            Row(name: "缓冲目标", value: ms(tgtMs),
                hint: "自适应算法想要的深度。比实际高说明它正在往上追"),
            Row(name: "丢包率", value: pct(lossPct), alert: lossPct > 3),
            Row(name: "⭐️ 吞字次数 / 分钟", value: String(format: "%.0f", concealRate * 60),
                hint: "丢包隐藏被触发的频率。**这个才对应你听到的卡顿** —— 有 FEC 兜底时丢包不等于吞字",
                alert: concealRate * 60 > 6),
            Row(name: "⭐️ 到得太晚被丢 / 分钟", value: String(format: "%.0f", discardRate * 60),
                hint: "包其实到了，只是晚了。**这是缓冲不够的铁证** —— 这个数高就该抬高服务端的最小播放延迟",
                alert: discardRate * 60 > 6),
            Row(name: "猜出来的音频占比",
                value: totalSamples > 0 ? pct(concealed / totalSamples * 100) : "—",
                hint: "有多少样本不是收到的，是算法编的"),
            Row(name: "其中纯静音",
                value: totalSamples > 0
                    ? pct(Double(inb?.silentConcealedSamples ?? 0) / totalSamples * 100) : "—",
                hint: "最难听的那一种 —— 连编都编不出来，直接静音"),
            Row(name: "加速 / 减速样本",
                value: "\(int(inb?.removedSamplesForAcceleration)) / \(int(inb?.insertedSamplesForDeceleration))",
                hint: "缓冲在拉伸或压缩音频追进度，听感是音调发飘"),
            Row(name: "FEC 包收到", value: int(inb?.fecPacketsReceived),
                hint: "前向纠错真的在工作吗。一直是 0 说明没生效"),
            Row(name: "重传包收到", value: int(inb?.retransmittedPacketsReceived)),
            Row(name: "抖动", value: ms(inb?.jitter.map { $0 * 1000 })),
            Row(name: "当前音量", value: String(format: "%.3f", inb?.audioLevel ?? 0)),
            Row(name: "累计收到", value: bytes(inb?.bytesReceived)),
        ]))

        // ── C 上行 ────────────────────────────────────────────────────
        g.append(Group(title: "上行 · 我说的话", subtitle: "对面听我听得清不清", rows: [
            Row(name: "对端看到的丢包率",
                value: remIn?.fractionLost.map { pct($0 * 100) } ?? "—",
                hint: "它收我这一路丢了多少",
                alert: (remIn?.fractionLost ?? 0) > 0.03),
            Row(name: "对端回报的 RTT", value: ms(remIn?.roundTripTime.map { $0 * 1000 })),
            Row(name: "编码目标码率", value: kbps(outb?.targetBitrate)),
            Row(name: "累计发出", value: bytes(outb?.bytesSent)),
            Row(name: "发出包数", value: int(outb?.packetsSent)),
            Row(name: "重传包数", value: int(outb?.retransmittedPacketsSent)),
            Row(name: "发送延迟累计",
                value: ms(outb?.totalPacketSendDelay.map { $0 * 1000 })),
            Row(name: "质量受限原因", value: desc(outb?.qualityLimitationReason),
                hint: "编码器因为什么降质：带宽、CPU，还是没受限"),
        ]))

        // ⚠️ **回声消除效果（ERL / ERLE）和采集端丢样本拿不到。**
        // `AudioSourceStatistics` 这个类型在 SDK 里是有的，字段也齐，
        // 但 `TrackStatistics` **只把 `videoSource` 收进来了，没有 audioSource**
        // （它的 init 里就一句 `compactMap { $0 as? VideoSourceStatistics }`）。
        // 所以那几项目前无解，除非上游补上或者我们自己去拿原始 report。
        // 写在这儿是免得下次有人又去找一遍。

        // ── D 编解码 ──────────────────────────────────────────────────
        g.append(Group(title: "编解码", subtitle: "实际协商出来的是什么", rows: [
            Row(name: "编码格式", value: codec?.mimeType ?? "—",
                hint: "看得出 RED（冗余编码）有没有生效"),
            Row(name: "采样率", value: codec?.clockRate.map { "\($0) Hz" } ?? "—"),
            Row(name: "声道", value: int(codec?.channels)),
            Row(name: "fmtp", value: codec?.sdpFmtpLine ?? "—",
                hint: "里面能看到 useinbandfec、usedtx 这些真实协商结果"),
            Row(name: "解码器", value: inb?.decoderImplementation ?? "—"),
        ]))

        groups = g
        updatedAt = Self.clock.string(from: Date())
    }

    /// 求每秒增量。第一帧没有基准，返回 0 而不是一个巨大的假速率。
    private func rate(_ key: String, _ total: Double) -> Double {
        defer { prev[key] = total }
        guard let last = prev[key] else { return 0 }
        return max(0, total - last)     // 采样间隔就是 1 秒
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    // MARK: - 格式化

    private func transportDesc(_ l: IceCandidateStatistics?, _ r: IceCandidateStatistics?) -> String {
        // relayProtocol 只有走 TURN 时才有值；tcpType 有值就说明这条是 TCP 候选。
        if let relay = l?.relayProtocol ?? r?.relayProtocol { return "中转 · \(desc(relay))" }
        if l?.tcpType != nil || r?.tcpType != nil { return "TCP" }
        if l?.candidateType != nil || r?.candidateType != nil { return "UDP" }
        return "—"
    }

    private func desc(_ v: Any?) -> String {
        guard let v else { return "—" }
        return String(describing: v)
    }

    private func ms(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "—" }
    private func pct(_ v: Double?) -> String { v.map { String(format: "%.2f %%", $0) } ?? "—" }
    private func kbps(_ v: Double?) -> String { v.map { String(format: "%.0f kbps", $0 / 1000) } ?? "—" }
    private func int(_ v: (some BinaryInteger)?) -> String { v.map { "\($0)" } ?? "—" }
    private func bytes(_ v: UInt64?) -> String {
        guard let v else { return "—" }
        let mb = Double(v) / 1024 / 1024
        return mb >= 1 ? String(format: "%.2f MB", mb) : String(format: "%.0f KB", Double(v) / 1024)
    }
}

/// 诊断页。从汉堡菜单进，看完关上。
///
/// **不做成常驻**：这些数字平时是噪音，只在「刚才怎么又卡了」那一刻才值钱。
/// 常驻会让人养成盯着仪表盘的习惯，而不是听内容。
struct CCDiagnosticsView: View {
    @Environment(CCRooms.self) private var rooms
    @State private var diag = CCDiagnostics()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    #if os(iOS) || os(visionOS)
                    // 「改了没效果」和「改了但根本没跑到」长得一模一样，
                    // 所以把最后一次实际落下去的配置显示出来。
                    LabeledContent {
                        Text(verbatim: CCAudioSessionPolicy.shared.lastApplied)
                            .font(.caption).multilineTextAlignment(.trailing)
                    } label: {
                        Text(verbatim: "音频会话")
                    }
                    LabeledContent {
                        Text(verbatim: CCAudioSessionPolicy.shared.lastRecovery)
                            .font(.caption).multilineTextAlignment(.trailing)
                    } label: {
                        Text(verbatim: "最近自愈")
                    }
                    // 「让出麦克风」的**前提条件**。设失败的话整个功能静默退化，
                    // 而上面两行看起来会完全正常 —— 2026-09-21 就是这么卡住一轮的。
                    LabeledContent {
                        Text(verbatim: CCAudioSessionPolicy.shared.muteMode)
                            .font(.caption).multilineTextAlignment(.trailing)
                    } label: {
                        Text(verbatim: "静音模式")
                    }
                    #endif
                    LabeledContent {
                        Text(verbatim: rooms.activeName)
                    } label: {
                        Text(verbatim: "房间")
                    }
                    LabeledContent {
                        Text(verbatim: diag.updatedAt).monospacedDigit()
                    } label: {
                        Text(verbatim: "刷新于")
                    }
                } footer: {
                    Text(verbatim: "每秒采一次。带 ⭐️ 的两行是判断「该不该加深缓冲」的关键：吞字次数高但到得太晚很少 → 是真丢包，加缓冲没用；到得太晚很多 → 包其实到了只是晚了，抬高服务端的最小播放延迟就能救。")
                }

                ForEach(diag.groups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                LabeledContent {
                                    Text(verbatim: row.value)
                                        .font(CC.Font.numeric)
                                        .foregroundStyle(row.alert ? AnyShapeStyle(.fgSerious) : AnyShapeStyle(.fg0))
                                } label: {
                                    Text(verbatim: row.name)
                                }
                                if let hint = row.hint {
                                    Text(verbatim: hint)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.fg3)
                                }
                            }
                        }
                    } header: {
                        Text(verbatim: group.title)
                    } footer: {
                        Text(verbatim: group.subtitle)
                    }
                }
            }
            .navigationTitle(Text(verbatim: "连接诊断"))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: { Text(verbatim: "完成") }
                    }
                }
        }
        // 同 CCNetReadout：`start` 是同步的 MainActor 方法，走 `onChange` 而不是
        // `task(id:)` —— 后者的闭包是 `@Sendable`，不保证继承主 actor。
        .onChange(of: rooms.activeName, initial: true) { _, _ in
            diag.start(remote: rooms.active?.agentAudioTrack,
                       local: rooms.active?.localMedia.microphoneTrack)
        }
        .onDisappear { diag.stop() }
    }
}
