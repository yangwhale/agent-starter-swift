#if os(iOS) || os(visionOS)
import Observation
import AVFAudio
import Foundation
import LiveKit
#if os(iOS)
import UIKit
#endif

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
@Observable
final class CCAudioSessionPolicy {
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
    private(set) var isCapturing = false

    /// 真机上用来确认它到底有没有生效 —— 诊断页读这个。
    /// 没有这行的话，「改了没效果」和「改了但没跑到」长得一模一样。
    private(set) var lastApplied: String = "（还没配置过）"

    /// 最近一次自愈：什么时候、为什么。诊断页看这个。
    private(set) var lastRecovery = "（还没发生过）"

    /// 静音模式设成了什么。
    ///
    /// ## 为什么这条必须上诊断页
    ///
    /// `.restart` 是「让出麦克风」成立的**前提**：默认那个 `.voiceProcessing`
    /// 的静音法是「引擎照录、只把输入置零」，那样闭麦期间麦克风仍然被占着。
    /// 设失败的话整个功能静默退化 —— 开关看着是开的、策略也装上了、
    /// 诊断页一切正常，**只有麦克风灯还亮着**。
    ///
    /// ⚠️ 原来它只 `print` 一行。2026-09-21 Chris 报「让出不生效」时，
    /// 我手上有诊断页却**分不清是这里失败了还是自愈把麦抢回去了** ——
    /// 两者在诊断页上长得一模一样。
    /// ⇒ **一个功能的前提条件，要跟这个功能的状态摆在一起看得见。**
    private(set) var muteMode = "（还没设过）"

    private let observer = Observer()
    private var installed = false
    private var recoveryInstalled = false
    /// 我们自己管类别时，最后一次算出来的那套。自愈要原样再设一遍。
    ///
    /// ⚠️ **释放那条路不写它**（`report` 传的 `config` 是 nil）。
    /// 所以让出麦克风之后，这里存的仍然是「上一次录音用的那套」——
    /// 见 `isReleased`，自愈必须先看那个再决定要不要用这份配置。
    private var lastConfig: AudioSessionConfiguration?

    /// 现在是不是「已经把麦克风让出去了」。
    ///
    /// ## 这个标记是 2026-09-21 补的，补的是一个**机制互相抵消**的 bug
    ///
    /// Chris：「不说话时让出麦克风为啥不生效，麦克风的灯还是亮着。」
    /// 诊断页显示「录音中 → PlayAndRecord」＋「回前台自检 → 已重新激活」，
    /// 而他确认**麦克风是关着的**。
    ///
    /// 源码对上了：`recover()` 每次回前台都跑，做的事是
    /// **把类别设回 `lastConfig` 然后无条件 `setActive(true)`**。
    /// 而 `lastConfig` 在释放时不更新 —— 它存的还是录音那套。
    ///
    ///     闭麦 → 释放（麦让出去了）→ 切后台 → 切回前台
    ///          → 自愈把「录音那套」原样装回来 → **麦克风被抢回来**
    ///          → 引擎状态没变，`apply()` 的去重挡住，**再也不会让出去**
    ///
    /// ⚠️ 两边单独看都完全正常：自愈成功了、让出也成功过。
    /// **是顺序一叠才互相抵消** —— 这类 bug 在任何一侧的日志里都看不出问题。
    ///
    /// ⇒ 一般化：**加一个「无条件恢复」之前，先列出它会覆盖掉哪些正常状态。**
    /// 「无条件」是为了不依赖猜出来的判据（那个理由现在依然成立），
    /// 但它的代价是**它也不区分「坏了」和「本来就该是这样」**。
    private var isReleased = false

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
            muteMode = "restart（闭麦真的停录音）"
            // ⚠️ **诊断页显示一份，日志也要打一份。**
            //
            // 这一行是 2026-09-22 补的，起因很具体：tommy（跑在 Mac 上、
            // 看不到屏幕）拿不到这个量 —— 它只在诊断页显示。
            // 于是我给它定的失败判据「静音模式 restart 而灯还亮」
            // **它结构上执行不了**，只能拿一个能看到的代理去顶替，然后判错。
            //
            // ⇒ 判据分配是**可以设计的**，不是「这个量恰好在不在日志里」。
            //   一行 print 的成本，换掉一整轮「让人去截图」的往返。
            print("[CCAudioSessionPolicy] 静音模式：\(muteMode)")
        } catch {
            // 不致命：只是静音时麦克风仍被占着，退回今天的行为。
            // **但一定要让人看得见** —— 见 `muteMode` 上面那段。
            muteMode = "⚠️ 设置失败，闭麦仍占麦: \(error.localizedDescription)"
            print("[CCAudioSessionPolicy] 静音模式：\(muteMode)")
        }

        observer.onApply = { [weak self] text, capturing, released, config in
            Task { @MainActor in
                self?.lastApplied = text
                self?.isCapturing = capturing
                self?.isReleased = released
                if let config { self?.lastConfig = config }
            }
        }
        lastApplied = "已接管，等引擎第一次启动"
    }

    // MARK: - 被打断之后自己爬起来

    /// **跟「让出麦克风」那个开关无关，永远装。**
    ///
    /// 这两件事是两个毛病，不该绑在一个开关上：让出麦克风是想让别的 App
    /// 能用麦；这一段是防「App 还活着但彻底哑了」。
    ///
    /// ## 症状
    ///
    /// Chris 2026-09-20：「后台放久了以后就没声了。下一次 bot 说话它不出声，
    /// 我去点，应用也没退出，就是单纯的不出声。」
    ///
    /// ## 为什么会哑
    ///
    /// iOS 会在来电话、Siri、闹钟、别的 App 抢独占音频、以及音频服务自己
    /// 重启的时候**把我们的 session 停掉**，然后发一条通知。
    ///
    /// ⚠️ **中断结束时 iOS 不会替你重新激活** —— 这是最容易漏的一条：
    /// `.ended` 只是告诉你「可以了」，`setActive(true)` 得自己调。
    /// 不调的话 session 就一直停着：WebRTC 照收音频帧，一个字也出不了喇叭。
    /// **App 活着、连接正常、界面一切如常，就是没声音** —— 正是 Chris 描述的样子。
    ///
    /// 扒过了：app 里一处中断处理都没有，`client-sdk-swift` 2.17.0 的 Swift 层
    /// 也没有（WebRTC 那个 xcframework 里有没有我看不到源码，**不下结论**；
    /// 但这个毛病现在就在发生，说明现有的那些不够）。
    func installRecovery() {
        guard !recoveryInstalled else { return }
        recoveryInstalled = true

        let nc = NotificationCenter.default

        nc.addObserver(forName: AVAudioSession.interruptionNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                switch type {
                case .began:
                    self?.lastRecovery = "被打断了（等结束）"
                case .ended:
                    // **不看 `.shouldResume`。** 那个标志是给「恢复播放一首歌」
                    // 设计的；我们是一条随时可能来声音的实时连接，
                    // 无论如何都得把 session 抢回来。
                    self?.recover(reason: "中断结束")
                @unknown default:
                    self?.recover(reason: "未知中断类型")
                }
            }
        }

        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                       object: nil, queue: .main) { [weak self] _ in
            // 音频服务整个重启了，所有音频对象都作废。重设一遍是必须的第一步；
            // 光这一步够不够我不确定，所以**要在诊断页看得见它发生过** ——
            // 「偶尔哑一次」和「音频服务崩过」必须能分开。
            Task { @MainActor in self?.recover(reason: "⚠️ 音频服务重启过") }
        }

        nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
            else { return }
            // 耳机拔了 / 蓝牙断了。iOS 会暂停，我们要接着放。
            Task { @MainActor in self?.recover(reason: "设备拔掉了") }
        }

        #if os(iOS)
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification,
                       object: nil, queue: .main) { [weak self] _ in
            // **兜底。** 上面三条哪条漏了，回前台这一下也能救回来 ——
            // 而「我去点开」正是 Chris 发现哑掉的那个时刻。
            Task { @MainActor in self?.recover(reason: "回前台自检") }
        }
        #endif
    }

    /// ⚠️ **不做「只在哑了的时候才修」的聪明判断。**
    ///
    /// 系统**没有公开 API 能查 session 还是不是激活的**（`isOtherAudioPlaying`
    /// 问的是别人，不是自己）。想省这一下就只能靠一个猜出来的判据 ——
    /// 而这个 bug 本身就难复现，一个猜错的判据会让它继续难复现。
    ///
    /// 直接无条件 `setActive(true)`：对已经激活的 session 它基本是空操作，
    /// 一次前台切换一次，代价可以忽略。
    private func recover(reason: String) {
        // **让出状态下什么都不做。** 这里没有东西需要恢复：
        // 没在放音也没在录音，而 `setActive(true)` 会把麦克风重新抓回来。
        //
        // 不怕漏救：bot 一开口，引擎就会 enable playout，
        // `apply()` 立刻会把 session 配起来 —— 那条路本来就走得通。
        guard !isReleased else {
            lastRecovery = "\(reason) → 跳过（当前是让出状态，没有东西要恢复）"
            print("[CCAudioSessionPolicy] \(lastRecovery)")
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // 自己管类别的时候要把类别也重设一遍：中断期间 iOS 可能改过它。
            if let config = lastConfig {
                try session.setCategory(config.category,
                                        mode: config.mode,
                                        options: config.categoryOptions)
            }
            try session.setActive(true)
            lastRecovery = "\(reason) → 已重新激活（引擎在跑：\(AudioManager.shared.isEngineRunning)）"
        } catch {
            lastRecovery = "\(reason) → 重新激活失败: \(error)"
        }
        print("[CCAudioSessionPolicy] \(lastRecovery)")
    }

    // MARK: - 观察者

    /// 引擎每次开/关都会带着「现在在不在放音、在不在录音」调进来。
    ///
    /// ⚠️ **每个方法都必须把调用传给 `next`**，否则后面的 mixer 收不到，
    /// 音频直接没了。协议默认实现会转发，我们重写的这两个要自己转。
    private final class Observer: AudioEngineObserver, @unchecked Sendable {
        var next: (any AudioEngineObserver)?
        /// `(文案, 在不在录音, 是不是让出状态, 这次算出来的配置)`
        ///
        /// ⚠️ **`released` 必须是独立的一位，不能用「config 是 nil」去推** ——
        /// 配置失败那条路 config 也是 nil，但那不是让出状态，
        /// 那种时候恰恰需要自愈去救。两件事挤在一个信号里迟早混。
        var onApply: ((String, Bool, Bool, AudioSessionConfiguration?) -> Void)?

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
                    report("已释放（麦克风让出去了）", capturing: false, released: true)
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
                       capturing: isRecordingEnabled, released: false, config: config)
            } catch {
                // 配置失败就当没通 —— **宁可绿灯不亮，也不能让人对着坏的麦说话。**
                report("配置失败: \(error)", capturing: false)
            }
        }

        private func report(_ text: String, capturing: Bool,
                            released: Bool = false,
                            config: AudioSessionConfiguration? = nil) {
            print("[CCAudioSessionPolicy] \(text)")
            onApply?(text, capturing, released, config)
        }
    }
}
#endif
