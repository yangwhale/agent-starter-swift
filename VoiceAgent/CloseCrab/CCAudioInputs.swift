#if os(macOS)

    import CoreAudio
    import Foundation
    import LiveKit
    import Observation

    /// Mac 上的**麦克风输入设备清单** —— 自己枚举、自己刷新，不靠 SDK 那份快照。
    ///
    /// ## 为什么不直接用 `localMedia.audioDevices`
    ///
    /// 那份清单在 SDK 里是这么来的（`LocalMedia.swift`，2.17.0）：
    ///
    /// ```swift
    /// @Published var audioDevices = AudioManager.shared.inputDevices   // ① 建对象那一刻的快照
    /// AudioManager.shared.onDeviceUpdate = { ... audioDevices = ... }  // ② 之后只靠这个回调
    /// ```
    ///
    /// 两处都对我们不成立：
    ///
    /// **① 快照取得太早。** `LocalMedia` 是在 `CCRoomSlot.init` 里建的 ——
    /// 建房间槽位的时候，麦克风还没开、WebRTC 的音频设备模块还没热起来。
    ///
    /// **② 那个回调是个全局单槽，而我们有 N 个房间。**
    /// `AudioManager.shared.onDeviceUpdate` 只有一个位置，每建一个 `LocalMedia`
    /// 就覆盖一次 —— 五个房间就覆盖五次，只有最后那个生效。
    /// 更糟的是 `LocalMedia.deinit` 会把它**置回 nil**：
    /// 随便关掉一个房间，哪怕它不是当前装着回调的那个，回调也没了。
    /// 从此设备插拔再也不会刷新。
    ///
    /// ⚠️ 这不是上游写错了 —— 上游假设的是「一个 app 一个 `LocalMedia`」，
    /// 那个假设下单槽完全够用。是**我们的多房间用法**踩出了这个坑。
    /// （同族：`feedback_default-is-tuned-for-someone-elses-usage`。）
    ///
    /// ## 我们自己怎么做
    ///
    /// 挂 CoreAudio 的属性监听 —— **系统设置里那个列表用的就是这套 API**，
    /// 所以我们看到的和 Chris 在系统里看到的必然是同一批设备。
    /// 监听是进程级的、跟房间数量无关，不存在被谁覆盖的问题。
    ///
    /// ## 它同时是一个对账工具
    ///
    /// 2026-09-21 现场：系统认得 5 个输入设备（AirPods / USB 声卡 AU05 /
    /// 罗技摄像头 / 内置麦 / iPhone 连续互通），而菜单里**只有一条**，
    /// 正好是默认那个。原因当时有两种可能分不开：
    ///
    /// - 快照太早 ／ 回调被吃掉 ⇒ 是**我们**的问题
    /// - WebRTC 那层本身只报一个 ⇒ 是**SDK/底层**的问题
    ///
    /// 所以这里**两份清单都留着**：`devices` 是 LiveKit 那份（菜单必须用它，
    /// 因为切设备只能走 LiveKit），`systemInputs` 是 CoreAudio 那份（真相）。
    /// 两份对不上就打日志、并在菜单底下显示一行提示 ——
    /// **让下一张截图自己带上证据**，不用再让人接调试器。
    @MainActor
    @Observable
    final class CCAudioInputs {
        static let shared = CCAudioInputs()

        /// LiveKit 认得的输入设备。**菜单用这份** —— 切设备只能把
        /// LiveKit 的 `AudioDevice` 交回给它，拿 CoreAudio 的 ID 去凑没用。
        private(set) var devices: [AudioDevice] = []

        /// 系统（CoreAudio）认得的输入设备名。**只用来对账**，不驱动界面。
        private(set) var systemInputs: [String] = []

        /// 当前真正在用的那个设备。
        ///
        /// ⚠️ **不要用 `localMedia.selectedAudioDeviceID`。** 它在 SDK 里是这么更新的：
        ///
        /// ```swift
        /// selectedAudioDeviceID = AudioManager.shared.defaultInputDevice.deviceId
        /// ```
        ///
        /// 而 `defaultInputDevice` 是个 `let`，**AudioManager 建的时候就定死了**。
        /// 于是：你手动选了 USB 麦 → 过一会儿插拔了别的东西触发一次设备更新 →
        /// 勾选跳回启动时的那个默认设备，**可实际在用的还是 USB 麦**。
        /// 界面和现实对不上，而且看起来像「我的选择被吃了」。
        ///
        /// 这里读 `inputDevice`（当前的），不读 `defaultInputDevice`（开机时的）。
        private(set) var selectedID: String = ""

        /// 两份清单对不上时给界面看的一句话；一致时是 nil。
        var mismatch: String? {
            guard !systemInputs.isEmpty, devices.count < systemInputs.count else { return nil }
            return "系统有 \(systemInputs.count) 个输入设备，这里只拿到 \(devices.count) 个"
        }

        private var listening = false

        private init() {}

        /// 重新读两份清单。**可以随便调** —— 两次 CoreAudio 查询，没有副作用。
        func refresh() {
            let before = devices.map(\.deviceId)

            devices = AudioManager.shared.inputDevices
            systemInputs = Self.coreAudioInputNames()
            selectedID = AudioManager.shared.inputDevice.deviceId

            let after = devices.map(\.deviceId)
            guard before != after || !listening else { return }
            log()
        }

        /// 开始跟着系统走。**幂等**，界面每次出现都可以调。
        func start() {
            refresh()
            guard !listening else { return }
            listening = true

            // 两件事都要听：**设备增减**（插了个 USB 麦）和**默认设备变化**
            // （AirPods 连上了）。只听前者的话，戴上耳机不算「设备列表变了」，
            // 名单是对的但勾选在错的地方。
            for selector in [kAudioHardwarePropertyDevices,
                             kAudioHardwarePropertyDefaultInputDevice]
            {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                // 回调队列指定主队列 ⇒ 块一定在主线程跑，`assumeIsolated` 才成立。
                // 换成 nil（用 CoreAudio 自己的线程）这里就会在 Swift 6 下崩。
                _ = AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
                ) { _, _ in
                    MainActor.assumeIsolated { CCAudioInputs.shared.refresh() }
                }
            }
        }

        private func log() {
            let lk = devices.isEmpty ? "（空）" : devices.map(\.name).joined(separator: " / ")
            let sys = systemInputs.isEmpty ? "（空）" : systemInputs.joined(separator: " / ")
            print("[CCAudioInputs] LiveKit \(devices.count) 个: \(lk)")
            print("[CCAudioInputs] 系统     \(systemInputs.count) 个: \(sys)")
            if let mismatch { print("[CCAudioInputs] ⚠️ \(mismatch)") }
        }

        // MARK: - CoreAudio

        /// 系统认得的输入设备名。判据是**有没有输入声道**，不是设备名字里有没有
        /// "Microphone" —— 名字是人起的（"AU05"、"Chris-AirPods3"），
        /// 拿它做匹配迟早出错。
        private static func coreAudioInputNames() -> [String] {
            deviceIDs()
                .filter { inputChannels(of: $0) > 0 }
                .compactMap { name(of: $0) }
        }

        private static func deviceIDs() -> [AudioObjectID] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            let system = AudioObjectID(kAudioObjectSystemObject)
            guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
                  size > 0
            else { return [] }

            var ids = [AudioObjectID](
                repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size
            )
            guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
            else { return [] }
            return ids
        }

        /// 输入声道数。0 就不是输入设备（扬声器、显示器都会出现在设备列表里）。
        private static func inputChannels(of id: AudioObjectID) -> Int {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
                  size > 0
            else { return 0 }

            // `AudioBufferList` 是**变长结构**（尾部跟着 N 个 AudioBuffer），
            // 不能按 `MemoryLayout<AudioBufferList>.size` 分配 —— 那只够一个 buffer，
            // 多流设备会越界。所以按系统给的 size 手动分配。
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(size),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr
            else { return 0 }

            let list = UnsafeMutableAudioBufferListPointer(
                raw.assumingMemoryBound(to: AudioBufferList.self)
            )
            return list.reduce(0) { $0 + Int($1.mNumberChannels) }
        }

        private static func name(of id: AudioObjectID) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<CFString?>.size)
            var value: CFString?
            let status = withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
            }
            guard status == noErr, let value else { return nil }
            return value as String
        }
    }

#endif
