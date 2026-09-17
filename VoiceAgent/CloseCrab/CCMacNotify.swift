#if os(macOS)

    import AppKit
    import UserNotifications

    /// 「它说完了」的系统通知。
    ///
    /// ## 为什么只有 Mac 需要
    ///
    /// iOS 上你盯着屏幕等它回答；**Mac 上你早切去干别的了** ——
    /// 问完一个要查资料的问题，人就去看别的窗口，然后忘了这回事。
    /// 没有通知的话，答案说完就散在空气里。
    ///
    /// ## 三条克制原则
    ///
    /// 1. **只在 app 不在前台时发。** 你人就在窗口前还弹通知，是纯骚扰。
    /// 2. **不带内容。** 语音回答动辄几十秒，塞进通知横幅只会被截断成半句废话，
    ///    反而让人以为它就说了这么点。只说"谁说完了"，回去听。
    /// 3. **同一房间只留最新一条。** 用 identifier 覆盖，不堆通知中心。
    @MainActor
    enum CCMacNotify {
        private static var authorized = false
        private static var asked = false

        /// 第一次要发时才申请 —— 启动就弹权限框是最招人烦的做法，
        /// 而且那时候用户还不知道这通知是干嘛的，多半直接拒绝。
        static func ensureAuthorized() async {
            guard !asked else { return }
            asked = true
            do {
                authorized = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            } catch {
                authorized = false     // 拒了就拒了，不是错误路径
            }
        }

        /// agent 说完一轮。
        /// - Parameter room: 房间名，同时用作通知 id（同房间只留最新一条）。
        static func spoke(room: String) {
            // 人就在前台 → 什么都不做
            guard !NSApplication.shared.isActive else { return }
            Task {
                await ensureAuthorized()
                guard authorized else { return }
                let content = UNMutableNotificationContent()
                content.title = room
                content.body = "说完了"
                content.sound = .default
                let req = UNNotificationRequest(
                    identifier: "cc.spoke.\(room)",   // 同 id 覆盖，不堆积
                    content: content,
                    trigger: nil                      // 立刻投递
                )
                try? await UNUserNotificationCenter.current().add(req)
            }
        }
    }

#endif
