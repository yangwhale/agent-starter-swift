import AVFoundation
import Foundation
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// bot「等你回话」「刚干完」时叮一声。
///
/// Chris 2026-10-05 定的声音（不是从哪儿抄的）：
///
/// | 事件 | 音 |
/// |---|---|
/// | 等你回话 | 两声上扬：E6 1318.5 Hz 0.35 s 接 A6 1760 Hz 0.9 s |
/// | 刚干完 | 一声 C6 1046.5 Hz 1.0 s |
///
/// 每声 ＝ 基频正弦 ＋ 0.35×二倍频（额外 exp(−4t) 衰减）＋ 0.15×3.01 倍频（额外 exp(−9t)），
/// 包络 exp(−6t)、4 ms 起音，整段归一到峰值 0.6。
/// （3.01 不是笔误，是方案给的值 —— 第三个分音故意不落在整数倍上。照抄，别「修正」成 3。）
///
/// ## 为什么运行时合成，不放音频文件
///
/// 加一个资源文件就要动工程的资源表，而这个工程的文件是 tommy 在 Mac 上收的 ——
/// 多一处要同步的地方。几万个采样点算一次不到 1 ms，第一次用到时算好缓存起来。
///
/// ## 什么时候响（三道闸，缺一不响）
///
/// 1. 开关开着（`CCStore.faceChime`，默认开）
/// 2. 是**当前房间**（话筒对着的那个）—— 隔壁房间的脸会瞪眼，但不打断你
/// 3. app 在前台 —— 后台叮一声是通知该干的事，不是这里
///
/// 同一房间同一事件 3 秒内只响一次（`CCChimeGate`，离线测过）。
@MainActor
final class CCFaceChime {
    static let shared = CCFaceChime()

    private var gate = CCChimeGate()
    /// **必须强持有**：`AVAudioPlayer` 一被释放就停，局部变量的话一声都听不到。
    private var player: AVAudioPlayer?
    private lazy var waitingWAV: Data = Self.wav(Self.render([(1318.5, 0.35), (1760, 0.9)]))
    private lazy var finishedWAV: Data = Self.wav(Self.render([(1046.5, 1.0)]))

    private init() {}

    /// 由 `CCRooms` 接在每个槽位的 `botStatus.onFaceEvent` 上 —— **只有那一处调**。
    func note(_ event: CCFaceEvent, room: String, isActiveRoom: Bool) {
        guard CCStore.faceChime, isActiveRoom, Self.appIsForeground else { return }
        guard gate.admit("\(room)|\(event.rawValue)", at: Date().timeIntervalSinceReferenceDate) else { return }
        let data = event == .waiting ? waitingWAV : finishedWAV
        do {
            let p = try AVAudioPlayer(data: data)
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            // 静默失败的话「怎么不叮了」查不到任何线索。print 是因为从 Mac 拉设备日志
            // 只有 stdout 到得了（见 CCBotStatus 里同一句注释）。
            print("⚠️ [CCFaceChime] 播放失败: \(error)")
        }
    }

    private static var appIsForeground: Bool {
        #if os(iOS)
            UIApplication.shared.applicationState == .active
        #elseif os(macOS)
            NSApplication.shared.isActive
        #else
            true
        #endif
    }

    // MARK: - 合成

    nonisolated static let sampleRate = 44_100

    /// 几个音依次接起来，整段归一到峰值 0.6。
    nonisolated static func render(_ notes: [(freq: Double, dur: Double)]) -> [Float] {
        let sr = Double(sampleRate)
        var out: [Float] = []
        for (f, dur) in notes {
            let n = Int(dur * sr)
            out.reserveCapacity(out.count + n)
            for i in 0..<n {
                let t = Double(i) / sr
                let attack = min(1, t / 0.004)
                let env = attack * exp(-6 * t)
                let s = sin(2 * .pi * f * t)
                    + 0.35 * exp(-4 * t) * sin(2 * .pi * 2 * f * t)
                    + 0.15 * exp(-9 * t) * sin(2 * .pi * 3.01 * f * t)
                out.append(Float(env * s))
            }
        }
        let peak = out.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return out }
        let k = 0.6 / peak
        return out.map { $0 * k }
    }

    /// 单声道 16 位 PCM 的 WAV（内存里一份，`AVAudioPlayer(data:)` 直接吃）。
    nonisolated static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                                   // PCM
        u16(1)                                   // 单声道
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))              // 每秒字节数
        u16(2)                                   // 每帧字节数
        u16(16)                                  // 位深
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * Float(Int16.max))
            u16(UInt16(bitPattern: v))
        }
        return d
    }
}
