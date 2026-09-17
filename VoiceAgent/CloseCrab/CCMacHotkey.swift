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
        private var globalMonitor: Any?
        private var localMonitor: Any?
        private var observers: [NSObjectProtocol] = []

        /// 拿到当前活动房间的麦克风策略。房间会切，所以是闭包不是引用。
        private let micPolicy: @MainActor () -> CCMicPolicy?
        /// 当前麦克风是不是已经手动常开 —— `beginHold` 要据此判断是否该介入。
        private let isMicOn: @MainActor () -> Bool

        init(micPolicy: @escaping @MainActor () -> CCMicPolicy?,
             isMicOn: @escaping @MainActor () -> Bool) {
            self.micPolicy = micPolicy
            self.isMicOn = isMicOn
            refreshTrust()
        }

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

        /// 弹系统授权提示。用户点了「去授权」才调 —— 不要在启动时自动弹，
        /// 那是最招人烦的行为，而且用户多半会直接关掉。
        func requestTrust() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            isTrusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
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
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apply(self.machine.onFlagsChanged(
                        keyCode: event.keyCode,
                        optionPressed: event.modifierFlags.contains(.option)
                    ))
                }
            }
            isGlobalActive = globalMonitor != nil
        }

        /// 窗口聚焦时也要能用 —— 全局监听**不会**投递给自己这个 app 的事件。
        private func installLocal() {
            guard localMonitor == nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) {
                [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return event }
                    self.apply(self.machine.onFlagsChanged(
                        keyCode: event.keyCode,
                        optionPressed: event.modifierFlags.contains(.option)
                    ))
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
            if !isTrusted { return "未授权 —— 全局按键不可用，窗口内可用空格" }
            if !isGlobalActive { return "已授权但监听没挂上（重启 app 试试）" }
            return "全局按键已就绪：按住右 Option 说话"
        }

        /// 打开系统设置里对应那一页。自己跳过去，别让用户翻五层菜单。
        func openAccessibilitySettings() {
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
            if let url { NSWorkspace.shared.open(url) }
        }
    }

#endif
