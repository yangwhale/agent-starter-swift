#if os(iOS) || os(visionOS)
import AVFAudio
import Foundation
import LiveKit

/// 不说话的时候，把麦克风还给别的 App。
///
/// ## 症状
///
/// Chris 2026-09-20：「每一次我要用豆包语音输入法的时候，都得等半天它才能
/// 把麦抢过来。我日常大多数时候那个麦克风都是关着的。」
///
/// ## 为什么会这样（扒的是 client-sdk-swift 2.17.0 的源码，不是猜的）
///
/// 三件事叠在一起：
///
/// 1. **连上房间那一刻必定开一次麦。** `Session.start()` 里：
///    ```swift
///    dispatchesAgent = try await connect()
///    try await room.localParticipant.setMicrophone(enabled: true)   // 无条件
///    ```
///    `preConnectAudio: false` 也绕不过去，它只管「什么时候开」不管「开不开」
///    （详见 `CCMicPolicy` 开头那段）。我们随后立刻按回去，但已经晚了。
///
/// 2. **SDK 里那个标记是粘性的。** `AudioSessionEngineObserver`：
///    ```swift
///    // Sticky: true once recording engaged, cleared when the WebRTC engine stops.
///    var hasRecorded: Bool = false
///    …
///    guard state.isRecordingEnabled || state.hasRecorded else { return .playback }
///    ```
///    只要这一次连接里录过音，音频类别就钉在 `.playAndRecord` 上，**静音不松手**，
///    要等 WebRTC 引擎整个停下来才清。而我们的引擎一直在跑（要放 bot 的声音）。
///
///    这是它**故意**的，注释写着：中途换类别会把苹果的 Voice Processing I/O
///    拆掉、回声消除失效。对「正在通话」是对的 —— 但我们是**挂一整天、偶尔
///    说一句**，两种用法的最优解正好相反。
///
/// 3. **我们同时挂好几个房间，还声明了 `UIBackgroundModes: audio`。**
///    每连一个房间触发一次第 1 条，退到后台也照样占着。
///
/// ## 这个类做什么
///
/// 把「什么时候该占麦克风」这个决定从 SDK 手里拿回来：
///
/// - 关掉它的自动配置（`isAutomaticConfigurationEnabled = false`）——
///   ⚠️ **关掉之后它就彻底不碰 session 了**：不设类别、不激活、也不释放
///   （`configureIfNeeded` 第一行就是 `guard isAutomaticConfigurationEnabled`）。
///   所以这三件事下面都得自己做，少一件就是「一点声音都没有」。
/// - 把自己插进它的观察者链最前面。**不自己去 App 各处埋钩子**：
///   引擎会把 `isRecordingEnabled` 直接递给我们，那是唯一权威的信号，
///   比在 `CCRooms` / `CCMicPolicy` 每个改麦的地方各挂一处可靠得多。
/// - 类别只看当下：**在录音就 `.playAndRecord`，没录音就 `.playback`。**
///   没有那个粘性标记。
///
/// ## ⚠️ 光有上面这些还不够：静音模式也得换
///
/// 默认静音模式是 `.voiceProcessing` —— 它靠把输入节点静音来实现静音，
/// **引擎还在录**，于是 `isRecordingEnabled` 依然是 true，我们这边照样会
/// 判成要占麦。所以 `install()` 里把它切成 `.restart`（静音时真的把录音
/// 引擎停掉）。
///
/// 代价：重新开麦要等引擎重启，比原来慢一点。**这正是我们想换的那笔交易** ——
/// 拿「开口时慢一点」换「不说话时别人能用麦」。
///
/// ## 关不掉怎么办
///
/// 整套受设置页「不说话时让出麦克风」控制（`CCStore.releaseMicWhenIdle`），默认开。
/// 真机上要是出现「没声音 / 回声 / 开麦要等很久」，在设置里关掉它就退回
/// SDK 原来的行为，**不用重新编译**。
@MainActor
final class CCAudioSessionPolicy: ObservableObject {
    static let shared = CCAudioSessionPolicy()

    /// **引擎此刻真的在采集。** 界面拿它当「可以开口了」的判据。
    ///
    /// 为什么不用「按下去了」：那是**意图**，不是事实。按下到真的通，中间
    /// 隔着 `setMicrophone` 的往返，换成 `.restart` 静音模式之后还多一次
    /// 引擎重启。绿灯亮在意图上，人就会对着一个还没通的麦说话，第一个字
    /// 直接丢 —— 而丢字这件事当场看不出来，只能靠「说完发现没人回」发现。
    ///
    /// 为什么不用 `LocalMedia.isMicrophoneEnabled`：那是**轨道**的状态，
    /// 比意图准，但仍然不等于「音频引擎已经在往里灌采样」。这一条是引擎
    /// 自己报上来的，是这条链上最靠后、也最接近事实的那个信号。
    @Published private(set) var isCapturing = false

    /// 真机上用来确认它到底有没有生效 —— 诊断页读这个。
    /// 没有这行的话，「改了没效果」和「改了但没跑到」长得一模一样。
    private(set) var lastApplied: String = "（还没配置过）"

    private let observer = Observer()
    private var installed = false

    private init() {}

    /// 单一来源是 `CCStore.releaseMicWhenIdle`。**不要在这里再读一遍
    /// `UserDefaults`** —— 两处各判一次，默认值迟早会写歪一个。
    static var isEnabled: Bool { CCStore.releaseMicWhenIdle }

    /// **在 App 启动时调一次，连房间之前。**
    ///
    /// SDK 的文档明确说 `isAutomaticConfigurationEnabled` 要在连接前设。
    func install() {
        guard !installed, Self.isEnabled else { return }
        installed = true

        let manager = AudioManager.shared
        manager.audioSession.isAutomaticConfigurationEnabled = false

        // 链的顺序 = 调用顺序。我们排第一个，随后仍然把 SDK 原来那两个接上：
        //   audioSession —— 自动配置已关，它退化成透传，但仍在维护
        //                   `acquireSessionRequirement` 那套记账（SoundPlayer 用）
        //   mixer        —— 干实活的，**绝对不能漏**，漏了就没有混音输出
        manager.set(engineObservers: [observer, manager.audioSession, manager.mixer])

        // 默认的 .voiceProcessing 静音法「引擎照录只是把输入静音」，
        // 那样麦克风还是被占着。.restart 才是真的停录音。
        do {
            try manager.set(microphoneMuteMode: .restart)
        } catch {
            // 不致命：只是静音时麦克风仍被占着，退回今天的行为。
            print("[CCAudioSessionPolicy] 切静音模式失败，静音时仍会占麦: \(error)")
        }

        observer.onApply = { [weak self] text, capturing in
            Task { @MainActor in
                self?.lastApplied = text
                self?.isCapturing = capturing
            }
        }
        lastApplied = "已接管，等引擎第一次启动"
    }

    // MARK: - 观察者

    /// 引擎每次开/关都会带着「现在在不在放音、在不在录音」调进来。
    ///
    /// ⚠️ **每个方法都必须把调用传给 `next`**，否则后面的 mixer 收不到，
    /// 音频直接没了。协议默认实现会转发，我们重写的这两个要自己转。
    private final class Observer: AudioEngineObserver, @unchecked Sendable {
        var next: (any AudioEngineObserver)?
        var onApply: ((String, Bool) -> Void)?

        func engineWillEnable(_ engine: AVAudioEngine,
                              isPlayoutEnabled: Bool,
                              isRecordingEnabled: Bool) -> Int
        {
            apply(isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
            return next?.engineWillEnable(engine,
                                          isPlayoutEnabled: isPlayoutEnabled,
                                          isRecordingEnabled: isRecordingEnabled) ?? 0
        }

        func engineWillStart(_ engine: AVAudioEngine,
                             isPlayoutEnabled: Bool,
                             isRecordingEnabled: Bool) -> Int
        {
            // 静音模式 .restart 下，开/关麦是「引擎重启」而不是「引擎开关」，
            // 有些路径只走到 willStart。两处都配一次，`apply` 自己会去重。
            apply(isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
            return next?.engineWillStart(engine,
                                         isPlayoutEnabled: isPlayoutEnabled,
                                         isRecordingEnabled: isRecordingEnabled) ?? 0
        }

        func engineDidDisable(_ engine: AVAudioEngine,
                              isPlayoutEnabled: Bool,
                              isRecordingEnabled: Bool) -> Int
        {
            // 先让下游收拾完自己的东西，再去停 session —— 反过来的话
            // mixer 还在往一个已经失效的 session 上写。
            let result = next?.engineDidDisable(engine,
                                                isPlayoutEnabled: isPlayoutEnabled,
                                                isRecordingEnabled: isRecordingEnabled) ?? 0
            apply(isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
            return result
        }

        // MARK: -

        private var lastKey: String?

        private func apply(isPlayoutEnabled: Bool, isRecordingEnabled: Bool) {
            let key = "\(isPlayoutEnabled)-\(isRecordingEnabled)"
            guard key != lastKey else { return }   // 同一个状态别反复 setCategory
            lastKey = key

            let session = AVAudioSession.sharedInstance()

            guard isPlayoutEnabled || isRecordingEnabled else {
                // 两边都不要了：**必须显式释放**，而且要带
                // `.notifyOthersOnDeactivation` —— 不带的话被我们打断的那个
                // App（音乐、导航）不会自己恢复。
                do {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                    report("已释放（麦克风让出去了）", capturing: false)
                } catch {
                    report("释放失败: \(error)", capturing: false)
                }
                return
            }

            // ⭐ 这四行就是整个修复。没有粘性标记：这一刻不录音，就不占麦。
            let config: AudioSessionConfiguration = isRecordingEnabled
                ? (AudioManager.shared.audioSession.isSpeakerOutputPreferred
                    ? .playAndRecordSpeaker : .playAndRecordReceiver)
                : .playback

            do {
                try session.setCategory(config.category,
                                        mode: config.mode,
                                        options: config.categoryOptions)
                // WebRTC 想要 20 ms 的 IO 缓冲。SDK 自己管类别时也会设这一句，
                // 我们接管了就得跟着设 —— 不设的话某些机器会协商出更大的缓冲，
                // 报 kAudioUnitErr_TooManyFramesToProcess (-10874)。
                try session.setPreferredIOBufferDuration(0.02)
                try session.setActive(true)
                report("\(isRecordingEnabled ? "录音中" : "只放音") → \(config.category.rawValue)",
                       capturing: isRecordingEnabled)
            } catch {
                // 配置失败就当没通 —— **宁可绿灯不亮，也不能让人对着坏的麦说话。**
                report("配置失败: \(error)", capturing: false)
            }
        }

        private func report(_ text: String, capturing: Bool) {
            print("[CCAudioSessionPolicy] \(text)")
            onApply?(text, capturing)
        }
    }
}
#endif
