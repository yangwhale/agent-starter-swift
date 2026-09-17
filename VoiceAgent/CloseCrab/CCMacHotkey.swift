#if os(macOS)

    import AppKit
    import Combine
    import SwiftUI

    /// macOS 的按住说话：**全局热键 ＋ 窗口内空格**。
    ///
    /// ## 为什么 Mac 上必须有全局热键
    ///
    /// iOS 上 app 在前台你才会用它；**Mac 上它整天待在后台**。
    /// 一个「得先切过去、点一下、再按住屏幕」的语音助手，你不会用第二次。
    /// 右 Option 按住即说，不管你人在 Xcode 还是浏览器 —— 这才是 Mac 的用法。
    ///
    /// ## 权限：不是 entitlement，是用户手动授权
    ///
    /// 全局按键监听要**辅助功能**权限（系统设置 › 隐私与安全性 › 辅助功能）。
    /// 沙箱 app 可以申请，但**加 entitlement 没用** —— 只能引导用户去点。
    /// 所以：
    /// - 没授权时**不报错、不拦路**，退回窗口内空格那条路（那条不需要权限）
    /// - 状态暴露给设置页，让人知道「为什么全局按键不灵」
    ///
    /// ⚠️ 没有这个降级，用户会以为功能坏了 —— 而真相只是没点那个开关。
    @MainActor
    final class CCMacHotkey: ObservableObject {
        /// 辅助功能授权状态。设置页据此显示提示和「去授权」按钮。
        @Published private(set) var isTrusted = false
        /// 全局监听有没有真的挂上。授权了但挂失败也要看得见。
        @Published private(set) var isGlobalActive = false

        private var machine = CCPushToTalkMachine()

        /// 换触发键。配置页拨了就调，**不用重挂监听** ——
        /// 监听收的是所有 `.flagsChanged`，认哪个键是状态机的事。
        func setKey(_ key: CCPushToTalkKey) {
            let wasHolding = machine.isHolding
            machine.key = key
            // 换键时状态机自己会清 isHolding，但**麦克风得有人去关** ——
            // 不然按着旧键的那只手松开时没人收尾，麦克风就一直开着。
            if wasHolding { micPolicy()?.endHold() }
            isGlobalActive = globalMonitor != nil && key != .off
        }

        /// 把我们的修饰位枚举翻成 AppKit 的。
        ///
        /// 这一层翻译的存在意义：`CCPushToTalkMachine` 里不能出现
        /// `NSEvent.ModifierFlags`，否则那个文件就没法在 Linux 上测了。
        private static func pressed(_ flag: CCModifierFlag,
                                    in flags: NSEvent.ModifierFlags) -> Bool {
            switch flag {
            case .option: flags.contains(.option)
            case .command: flags.contains(.command)
            case .control: flags.contains(.control)
            case .shift: flags.contains(.shift)
            case .function: flags.contains(.function)
            }
        }

        private func isTriggerPressed(_ flags: NSEvent.ModifierFlags) -> Bool {
            guard let flag = machine.key.flag else { return false }
            return Self.pressed(flag, in: flags)
        }

        /// 事件监听的共同落点。**收标量，不收 `NSEvent`。**
        ///
        /// ⚠️ 这不是洁癖，是 Swift 6 的硬要求：`NSEvent` 明确标了
        /// `Sendable` 不可用，带着它从监听回调跨进 `MainActor` 是编译错误
        /// （`conformance of 'NSEvent' to 'Sendable' is unavailable`）。
        /// 所以在回调里就把 keyCode 和修饰位原始值取出来，只让标量过界。
        ///
        /// 顺带也让这一层跟 `CCPushToTalkMachine` 对齐了 —— 那个状态机本来
        /// 就只收标量，为的是能在没有 AppKit 的机器上离线测。
        private func handleFlagsChanged(keyCode: UInt16, rawFlags: UInt) {
            let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
            apply(machine.onFlagsChanged(keyCode: keyCode,
                                         optionPressed: isTriggerPressed(flags)))
        }

        private var globalMonitor: Any?
        private var localMonitor: Any?
        private var observers: [NSObjectProtocol] = []

        /// **单例**。底下那个全局事件监听只该有一个 ——
        /// 两个实例会各自 `addGlobalMonitorForEvents`，同一次按键触发两遍。
        static let shared = CCMacHotkey()

        /// 拿到当前活动房间的麦克风策略。房间会切，所以是闭包不是引用。
        private var micPolicyProvider: (@MainActor () -> CCMicPolicy?)?
        /// 当前麦克风是不是已经手动常开 —— `beginHold` 要据此判断是否该介入。
        private var isMicOnProvider: (@MainActor () -> Bool)?

        private init() { refreshTrust() }

        /// 根视图启动时把房间层接上。分两步是因为单例先于房间层存在。
        func bind(micPolicy: @escaping @MainActor () -> CCMicPolicy?,
                  isMicOn: @escaping @MainActor () -> Bool) {
            micPolicyProvider = micPolicy
            isMicOnProvider = isMicOn
        }

        private func micPolicy() -> CCMicPolicy? { micPolicyProvider?() }
        private func isMicOn() -> Bool { isMicOnProvider?() ?? false }

        deinit {
            // deinit 不在 MainActor 上，不能碰 @MainActor 成员；
            // 监听句柄是 Sendable 的引用，就地摘掉即可。
            if let g = globalMonitor { NSEvent.removeMonitor(g) }
            if let l = localMonitor { NSEvent.removeMonitor(l) }
        }

        // MARK: - 授权

        /// 只查不弹窗。用于界面显示。
        func refreshTrust() {
            isTrusted = AXIsProcessTrusted()
        }

        /// `kAXTrustedCheckOptionPrompt` 的字面值。
        ///
        /// ⚠️ **不能直接引用那个常量。** 它在 C 头文件里是个 `var`，
        /// Swift 6 严格并发据此判定「引用了共享可变状态」，直接编译失败：
        /// `reference to var 'kAXTrustedCheckOptionPrompt' is not
        /// concurrency-safe because it involves shared mutable state`。
        ///
        /// 它的字符串值是**文档化且稳定**的，所以直接写字面量 —— 这也是
        /// Swift 6 迁移里这一类 C 全局常量的通行解法，比 `nonisolated(unsafe)`
        /// 更诚实：我们要的本来就只是那个字符串。
        private static let axPromptOptionKey = "AXTrustedCheckOptionPrompt"

        /// 弹系统授权提示。用户点了「去授权」才调 —— 不要在启动时自动弹，
        /// 那是最招人烦的行为，而且用户多半会直接关掉。
        func requestTrust() {
            isTrusted = AXIsProcessTrustedWithOptions(
                [Self.axPromptOptionKey: true] as CFDictionary)
            // 授权是在系统设置里点的，进程内拿不到回调 ——
            // 只能等 app 重新激活时再查一次（见 start() 里的通知订阅）。
        }

        // MARK: - 挂载

        func start() {
            refreshTrust()
            installLocal()
            installGlobalIfTrusted()

            let nc = NotificationCenter.default
            // 切走 app 时必须强制收尾。**这是全局监听最容易漏的一步**：
            // 按下时我们在前台，按住过程中切走，抬起事件被别人吃掉 ——
            // 没有这一手就会卡在「一直在说话」，麦克风一直开着而界面上看不出来。
            observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(self?.machine.forceRelease() ?? .ignore) }
            })
            // 回到前台时重查授权 —— 用户可能刚在系统设置里点完开关
            observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshTrust()
                    self?.installGlobalIfTrusted()
                }
            })
            // 系统休眠同理：醒来时按键状态完全不可知
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(self?.machine.forceRelease() ?? .ignore) }
            })
        }

        private func installGlobalIfTrusted() {
            guard isTrusted, globalMonitor == nil else { return }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) {
                [weak self] event in
                // 标量先取出来，再进 MainActor —— 理由见 handleFlagsChanged。
                let code = event.keyCode
                let raw = event.modifierFlags.rawValue
                MainActor.assumeIsolated {
                    self?.handleFlagsChanged(keyCode: code, rawFlags: raw)
                }
            }
            isGlobalActive = globalMonitor != nil && machine.key != .off
        }

        /// 窗口聚焦时也要能用 —— 全局监听**不会**投递给自己这个 app 的事件。
        private func installLocal() {
            guard localMonitor == nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) {
                [weak self] event in
                let code = event.keyCode
                let raw = event.modifierFlags.rawValue
                MainActor.assumeIsolated {
                    self?.handleFlagsChanged(keyCode: code, rawFlags: raw)
                }
                return event    // 不吞事件，别人还要用
            }
        }

        // MARK: - 空格（窗口内，不需要授权）

        func space(down: Bool, isTextInputActive: Bool) {
            apply(machine.onSpace(down: down, isTextInputActive: isTextInputActive))
        }

        // MARK: -

        private func apply(_ action: CCPushToTalkMachine.Action) {
            guard let policy = micPolicy() else { return }
            switch action {
            case .begin: policy.beginHold(isMicrophoneEnabled: isMicOn())
            case .end: policy.endHold()
            case .ignore: break
            }
        }

        var isHolding: Bool { machine.isHolding }

        /// 一句话状态，给设置页显示。
        ///
        /// **必须显示**：没授权时全局热键静默不工作，用户只会觉得"坏了"，
        /// 而真相只是没点那个系统开关。静默失败比报错难查十倍。
        var statusText: String {
            if machine.key == .off { return "全局按键已关闭 —— 窗口内按住空格说话" }
            if !isTrusted { return "未授权 —— 全局按键不可用，窗口内可用空格" }
            if !isGlobalActive { return "已授权但监听没挂上（重启 app 试试）" }
            return "已就绪：按住\(machine.key.label)说话"
        }

        var currentKey: CCPushToTalkKey { machine.key }

        /// 打开系统设置里对应那一页。自己跳过去，别让用户翻五层菜单。
        func openAccessibilitySettings() {
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
            if let url { NSWorkspace.shared.open(url) }
        }
    }

#endif
