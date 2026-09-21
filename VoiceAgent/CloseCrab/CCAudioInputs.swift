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
    /// ## 它也曾是个判别工具，那个问题已经答完了
    ///
    /// 2026-09-21 现场：系统认得 5 个输入设备，而菜单里**只有一条**。
    /// 当时有两种可能分不开：快照太早（我们的问题） vs WebRTC 只报一个（底层的问题）。
    ///
    /// 冷启动日志给了答案：**同一个 SDK 调用，前后两次分别报 1 个和 6 个** ——
    /// 是快照太早，不是底层缺斤少两。
    ///
    /// 所以两份清单还都留着，但分工变了：
    /// - `devices`（LiveKit）—— **界面只用这份**，切设备也只能走它
    /// - `systemInputs`（CoreAudio）—— **只进日志**，用来解释异常
    ///
    /// ⚠️ 别再把 `systemInputs` 当「真相」用。实测它**比 LiveKit 那份还脏**
    /// （扬声器会报 4 个输入声道），详见 `coreAudioInputs` 上面那段。
    @MainActor
    @Observable
    final class CCAudioInputs {
        static let shared = CCAudioInputs()

        /// LiveKit 认得的输入设备。**菜单用这份** —— 切设备只能把
        /// LiveKit 的 `AudioDevice` 交回给它，拿 CoreAudio 的 ID 去凑没用。
        private(set) var devices: [AudioDevice] = []

        /// CoreAudio 侧的一条设备记录。**字段是为了对账，不是为了显示。**
        struct SystemInput {
            let uid: String
            let name: String
            let channels: Int
            /// 传输类型的四字符码，`grup` = 聚合设备、`virt` = 虚拟设备、
            /// `bltn` = 内置、`usb ` = USB、`blue` = 蓝牙、`unkn` = 未知。
            ///
            /// ⚠️ **`unkn` 不等于假货** —— iPhone 连续互通那个麦就是 `unkn`，
            /// 是真设备。所以过滤只能挑明确该排除的（聚合/虚拟），
            /// 不能用「不认识的一律扔掉」。
            let transport: String
            /// CoreAudio 自己标的「别给用户看」。系统设置就是靠它藏东西的。
            let hidden: Bool
            /// 这台设备**输入流**的终端类型（四字符码，一台设备可能有多条流）。
            ///
            /// 这是目前唯一**有希望**区分「真麦克风」和「扬声器回采通道」的字段 ——
            /// 声道数区分不了（扬声器报 4ch），传输类型也区分不了（两者都是 `bltn`）。
            /// 先打进日志攒证据，**还没拿它做过滤**。
            let terminals: [String]
        }

        /// 系统（CoreAudio）认得的输入设备。**只用来对账和打日志，不驱动界面。**
        private(set) var systemInputs: [SystemInput] = []

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

        // ⛔ 这里**曾经**有个 `mismatch`，把「系统 N 个 / 这里 M 个」显示在菜单底下。
        //    它的任务已经完成了（见类型注释里那段判别），而且**它给出的数是错的**：
        //    冷启动那一次报「系统有 10 个输入设备」，真实值是 5 —— 里面混进了
        //    扬声器、重复的 AirPods、还有 CoreAudio 给本进程建的聚合设备。
        //
        //    ⚠️ **一个会报错数的诊断，比没有诊断更坏。** 它会被当成事实引用，
        //    而且下次真出问题时没人信它。所以留日志、撤界面 ——
        //    日志是给知道上下文的人看的，界面上那行是给会拿它下结论的人看的。

        /// LiveKit 清单里那条**伪条目**的 id。
        ///
        /// 2026-09-21 实测：`AudioManager.shared.inputDevices` 的第一条
        /// **永远是 `id=default`**，`name` 借用当前默认设备的名字。
        /// 它不是一台设备，是「跟随系统默认」这个选项。
        ///
        /// ⇒ **菜单里那个"重复的 AirPods"就是它** —— 一条是 `default`
        ///   （名字借的 AirPods），一条是真的 `AC-C9-06-4D-33-EA:input`。
        ///   不是枚举重了，是两条**语义不同**的条目撞了名字。
        ///   所以修法是**改标签**，不是去重 —— 去重会把一个有用的选项删掉。
        static let followSystemID = "default"

        /// 菜单上显示什么。
        static func label(for device: AudioDevice) -> String {
            device.deviceId == followSystemID
                ? "跟随系统默认（\(device.name)）"
                : device.name
        }

        /// 这条是不是当前在用的。
        ///
        /// ⚠️ **`selectedID` 会是空串。** 冷启动那次日志里
        /// `AudioManager.shared.inputDevice.deviceId` 就是空的 ——
        /// 此时没有任何一条能匹配上，菜单里**一个勾都不打**，
        /// 看起来像「哪个都没选中」。
        ///
        /// 空串时按「在跟随系统默认」处理。**这是个假设**，推导链：
        /// 我们从没主动调过 `select`，而 app 确实在录音，
        /// 所以它用的只能是系统默认那一路。
        func isSelected(_ device: AudioDevice) -> Bool {
            selectedID.isEmpty
                ? device.deviceId == Self.followSystemID
                : device.deviceId == selectedID
        }

        private var listening = false

        private init() {}

        /// 重新读两份清单。**可以随便调** —— 两次 CoreAudio 查询，没有副作用。
        func refresh() {
            let before = devices.map(\.deviceId)

            devices = AudioManager.shared.inputDevices
            systemInputs = Self.coreAudioInputs()
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

        /// 把两份清单**连 ID 一起**打出来。
        ///
        /// ✅ **两边的 ID 是同一个东西** —— 2026-09-21 实测逐字相同
        /// （`AppleUSBAudioEngine:AU05:…`、`BuiltInMicrophoneDevice`、
        /// iPhone 那个 UUID 都对得上）。所以理论上可以拿一边去筛另一边。
        ///
        /// **但现在没这么做**，因为「拿哪一边去筛」这个问题的答案是反直觉的：
        /// 该被筛掉的是 CoreAudio 那份，不是 LiveKit 那份。
        ///
        /// 唯一的例外是 LiveKit 的第一条 `id=default` —— 它不是设备，
        /// 见 `followSystemID`。
        private func log() {
            print("[CCAudioInputs] ── LiveKit \(devices.count) 个 ──")
            for d in devices {
                print("[CCAudioInputs]   \(d.name)  id=\(d.deviceId)")
            }
            print("[CCAudioInputs] ── 系统 \(systemInputs.count) 个 ──")
            for s in systemInputs {
                let flags = s.hidden ? " HIDDEN" : ""
                let term = s.terminals.isEmpty ? "-" : s.terminals.joined(separator: ",")
                print("[CCAudioInputs]   \(s.name)  \(s.channels)ch \(s.transport) term=\(term)\(flags)  uid=\(s.uid)")
            }
            print("[CCAudioInputs] 当前选中 id=\(selectedID)")
        }

        // MARK: - CoreAudio

        /// 系统认得的输入设备。判据是**有没有输入声道**，不是设备名字里有没有
        /// "Microphone" —— 名字是人起的（"AU05"、"Chris-AirPods3"），
        /// 拿它做匹配迟早出错。
        ///
        /// ## ⚠️ 这份清单**只进日志，不驱动界面** —— 它比 LiveKit 那份还脏
        ///
        /// 2026-09-21 打了 ID 和声道数之后，事实是这样的：
        ///
        /// **「声道数 > 0 ＝ 输入设备」这条判据本身就错。**
        /// `MacBook Air Speakers`（`uid=BuiltInSpeakerDevice`）在**每一次**采样里
        /// 都报 **4 个输入声道**。不是查询失效、不是时序问题 ——
        /// 它在 CoreAudio 里确实声明了输入流（回声消除参考通道那类东西）。
        ///
        /// > 我和 tommy 当时各猜了一个机制（「ADM 没热」「查询返回非预期结果」），
        /// > **两个都错**。这是「不肯乱写过滤」的直接回报：
        /// > 真按「声道数 > 0」去筛，扬声器照样进来，而我们会以为过滤生效了。
        ///
        /// **而 LiveKit 那份反而干净些**：它从没报过扬声器、也没报过聚合设备。
        /// 所以**不要拿这份去筛那份** —— 会把好的换成坏的。
        ///
        /// ## 已知未解：清单在持续抖动
        ///
        /// 60 秒内四次采样，系统侧 10 / 6 / 10 / 10，LiveKit 侧 1 / 6 / 8 / 6，
        /// 没人插拔任何设备。`VPAUAggregateAudioDevice` 的地址每次都变，
        /// 说明语音处理单元在反复建销聚合设备。
        /// 连 `CADefaultDeviceAggregate-<pid>` 自己的声道数都在 1ch / 2ch 之间跳。
        ///
        /// ⇒ **用户在不同时机打开菜单，看到的条目数可能不同。**
        /// 这比「只有一条」更难查，因为它**间歇性正确**。
        ///
        /// ⛔ **现在没有证据支持任何一种过滤规则**，所以一条都不写。
        /// 差的两条（AirPods 的 `:output`、`Unknown USB Audio Device`）
        /// 靠 UID 后缀或名字能认出来，但那是字符串启发式，
        /// 跟我在 `coreAudioInputs` 上面写的「别拿名字做匹配」是同一个坑。
        /// 日志里多打了**输入流的终端类型**，那才是能区分
        /// 「麦克风」和「扬声器回采」的字段 —— 等下次有人回来看这块时用。
        private static func coreAudioInputs() -> [SystemInput] {
            deviceIDs().compactMap { id in
                let channels = inputChannels(of: id)
                guard channels > 0, let name = name(of: id) else { return nil }
                return SystemInput(
                    uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "?",
                    name: name,
                    channels: channels,
                    transport: fourCC(uint32Property(id, kAudioDevicePropertyTransportType)),
                    hidden: (uint32Property(id, kAudioDevicePropertyIsHidden) ?? 0) != 0,
                    terminals: inputTerminalTypes(of: id)
                )
            }
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

        /// 这台设备所有**输入流**的终端类型。
        ///
        /// 终端类型挂在**流**上不是挂在设备上 —— 一台设备可以既有麦克风流
        /// 又有回采流，这正是我们想分开的那种情况。所以要先列流再逐条问。
        private static func inputTerminalTypes(of id: AudioObjectID) -> [String] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
                  size > 0
            else { return [] }

            var streams = [AudioStreamID](
                repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size
            )
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr
            else { return [] }

            return streams.map { fourCC(uint32Property($0, kAudioStreamPropertyTerminalType)) }
        }

        private static func name(of id: AudioObjectID) -> String? {
            stringProperty(id, kAudioObjectPropertyName)
        }

        private static func stringProperty(
            _ id: AudioObjectID, _ selector: AudioObjectPropertySelector
        ) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
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

        private static func uint32Property(
            _ id: AudioObjectID, _ selector: AudioObjectPropertySelector
        ) -> UInt32? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<UInt32>.size)
            var value: UInt32 = 0
            let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
            return status == noErr ? value : nil
        }

        /// 四字符码转可读串。CoreAudio 里传输类型、编码格式这类常量都是
        /// `'grup'`、`'blue'` 这种四个 ASCII 字节塞进一个 UInt32。
        /// 打成十进制没法看，所以还原成字符。
        private static func fourCC(_ value: UInt32?) -> String {
            guard let value else { return "----" }
            let bytes = [
                UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
            ]
            // 不可打印的字节用 `.` 顶替，免得日志里蹦出控制字符。
            return String(bytes.map { (0x20 ... 0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
        }
    }

#endif
