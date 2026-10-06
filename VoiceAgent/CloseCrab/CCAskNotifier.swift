#if os(iOS)

    import Foundation
    import Observation
    import UIKit
    // `@preconcurrency`：UNNotificationResponse / UNUserNotificationCenter 在 SDK 里没标 Sendable，
    // delegate 回调又是 nonisolated 的 —— 万一 SDK 的标注跟这里的用法对不上，把那类 Sendable 诊断降级
    // （跟 CCLiveActivity 的 `@preconcurrency import ActivityKit` 同一个理由）。
    @preconcurrency import UserNotifications

    /// 「bot 在等你」的本地通知 —— **app 这一半**：盯着全部房间、发通知、撤通知、接通知上的按钮。
    ///
    /// 判定全在 `CCAskNotifyPolicy`（纯 Foundation，离线测过）。这里只做三件事：
    /// 1. 从房间层读信号（每个槽位的脸 / wait / 推荐答案 / 刚回复的时刻）
    /// 2. 问 Policy 该干什么
    /// 3. 调 UserNotifications
    ///
    /// ## 为什么是通知不是卡片（2026-10-06）
    ///
    /// 真机诊断：app 退到后台约 20 秒后系统就不收 `Activity.update` 了（苹果只认 APNs 推送，
    /// 我们的描述文件没有 aps-environment）。bot 举手时锁屏卡片多半显示不出来。本地通知不要推送权限，
    /// app 靠后台音频一直活着，能自己发。Chris 拍板的方案。
    ///
    /// ## 几条
    ///
    /// - **盯全部房间，不只当前那个**：在 bunny 房间时 jarvis 举手也要响（卡片只跟当前房间走，管不到这个）。
    /// - **通知上的按钮跟 app 里那几颗走同一个出口**：槽位的 `CCQuickReplySender.send` ——
    ///   发的是 LiveKit 文本流 `lk.chat`，「已回复」记在槽位上，app 里、锁屏卡片上都看得到。
    /// - **按钮不带 `.foreground`**：点了不把 app 拉到前台，在后台发完就完（app 本来就活着）。
    /// - **只在 app 不在前台时发**；前台的人看得到 app 里的按钮和卡片的提醒。
    @MainActor
    final class CCAskNotifier {
        static let shared = CCAskNotifier()
        private init() {}

        /// 收点击的转发器（系统只弱引用 delegate，这里持有它）。为什么单独一个类型，见 `CCAskNotifyDelegate`。
        private var delegate: CCAskNotifyDelegate?

        private weak var rooms: CCRooms?
        /// 每个房间的记账（`CCAskNotifyPolicy.Memo`），按房间名。
        private var memos: [String: CCAskNotifyPolicy.Memo] = [:]
        /// 每个房间那条挂着的通知用的 category。系统里注册的是**一整套**（`setNotificationCategories`
        /// 是整体替换），而别的房间挂着的通知还要它自己那组按钮 —— 所以每次发之前用这里的全部重建一遍。
        ///
        /// 存的是纯字符串描述（`CategorySpec`），不是 `UNNotificationCategory` 对象：后者不是 Sendable，
        /// 存在本类（MainActor）里再送进 async 的系统调用，Swift 6 会判 `sending ... risks causing data races`
        /// （CCLiveActivity 文件头那节同一类问题）。对象在 `deliver` 里现建。
        private var categories: [String: CategorySpec] = [:]
        /// 通知权限问过没有（这个进程里只问一次；系统本身也只弹一次框）。
        private var askedAuthorization = false

        /// 观察登记着没有。同一时刻只能有一份登记 —— 理由同 `CCLiveActivity.armed`。
        private var armed = false

        nonisolated struct CategorySpec: Hashable, Sendable {
            var id: String
            /// (action identifier, 按钮上的字)
            var actions: [Action]
            nonisolated struct Action: Hashable, Sendable {
                var id: String
                var title: String
            }
        }

        // MARK: - 接线

        /// 接上房间层。**只调一次**（`VoiceAgentApp.init`）。
        ///
        /// delegate 要在 app 启动完成之前装好：app 被杀之后用户点了通知上的按钮，系统把 app
        /// 在后台拉起来、紧接着就投递那次点击 —— 晚装就收不到。app 里此前没有别处设过这个 delegate
        /// （Mac 上的 `CCMacNotify` 只发不收，而且这个文件只在 iOS 上编）。
        func attach(rooms: CCRooms) {
            self.rooms = rooms
            let forwarder = CCAskNotifyDelegate { [weak self] tap in
                await self?.handle(tap)
            }
            delegate = forwarder
            UNUserNotificationCenter.current().delegate = forwarder
            sync()
        }

        // MARK: - 主循环

        private struct RoomInput {
            var name: String
            var mood: CCFaceMood
            var wait: String
            var opts: [String]?
            var optl: [String]?
            var repliedAt: Date?
        }

        /// ⚠️ **无条件把要用的属性全读一遍**（每个槽位都读、每样都读）—— 观察登记的是
        /// **这次实际读到的**属性；条件读的话，那个条件翻转时没人通知我们（`CCLiveActivity.readInputs` 同一条）。
        private func readInputs(now: Date) -> (want: Bool, rooms: [RoomInput]) {
            guard let rooms else { return (false, []) }
            let list = rooms.slots.map { slot -> RoomInput in
                let snap = slot.botStatus.snap
                // 跟快捷回复条同一个判法（`CCQuickReplyBar.display` → `CCFaceMood.derive`）。
                // 只关心是不是 `.waiting`：derive 里压过「等你」的只有 没连上 / 找网络 / bot 不在 / 按住说话，
                // 说话、干活、刚干完都排在它后面 —— 所以那几个输入给常量，省得为它们白白多订阅（播放进度每秒一跳）。
                let mood = CCFaceMood.derive(
                    presence: rooms.presence(for: slot),
                    botPresent: slot.botPresent,
                    wait: snap?.wait ?? "",
                    on: false,
                    holding: slot.micPolicy.isHolding,
                    speaking: false,
                    muted: false,
                    finishedAt: nil,
                    now: now)
                return RoomInput(name: slot.name, mood: mood, wait: snap?.wait ?? "",
                                 opts: snap?.opts, optl: snap?.optl,
                                 repliedAt: slot.quickReply.repliedAt)
            }
            return (rooms.wantConnected, list)
        }

        private func sync() {
            let now = Date()
            let inputs: (want: Bool, rooms: [RoomInput])
            if armed {
                inputs = readInputs(now: now)
            } else {
                armed = true
                inputs = withObservationTracking {
                    readInputs(now: now)
                } onChange: { [weak self] in
                    // 这个回调在「即将改变」时、在任意线程上来：跳回主线程、等值落定再算。
                    Task { @MainActor in
                        self?.armed = false
                        self?.sync()
                    }
                }
            }
            apply(inputs.want, inputs.rooms, now: now)
        }

        private func apply(_ want: Bool, _ list: [RoomInput], now: Date) {
            // 第一次按「开始」时问通知权限：这时人在 app 里、刚表达了「我要用」，比启动就弹框好 ——
            // 启动就弹，用户还不知道这通知是干嘛的，多半直接拒（`CCMacNotify.ensureAuthorized` 同一条）。
            if want && !askedAuthorization {
                askedAuthorization = true
                Task {
                    do {
                        let ok = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                        print("[CCAskNotifier] 通知权限：\(ok ? "允许" : "拒绝")")
                    } catch {
                        print("[CCAskNotifier] 通知权限请求失败：\(error)")
                    }
                }
            }

            let active = UIApplication.shared.applicationState == .active

            // 房间被删掉了：它那条撤掉、记账丢掉。
            let names = Set(list.map(\.name))
            for gone in memos.keys where !names.contains(gone) {
                remove(room: gone)
                memos[gone] = nil
            }

            for r in list {
                let (memo, action) = CCAskNotifyPolicy.step(
                    memo: memos[r.name] ?? .empty, mood: r.mood, wait: r.wait,
                    repliedAt: r.repliedAt, appActive: active, now: now)
                memos[r.name] = memo
                switch action {
                case .none: break
                case let .post(text): post(room: r.name, text: text, opts: r.opts, optl: r.optl)
                case .remove: remove(room: r.name)
                }
            }
        }

        // MARK: - UserNotifications

        private func post(room: String, text: String, opts: [String]?, optl: [String]?) {
            let choices = CCAskNotifyPolicy.choices(options: opts, labels: optl)
            let catID = CCAskNotifyPolicy.categoryID(choices: choices)
            // 按钮上写短标签，点了发完整原句（句子在 userInfo 里，按下标取）。
            categories[room] = CategorySpec(id: catID, actions: choices.enumerated().map { i, c in
                .init(id: CCAskNotifyPolicy.actionID(index: i), title: c.short)
            })
            // 同一组按钮的房间共用一个 id：按 id 去重后整套交给系统。
            var byID: [String: CategorySpec] = [:]
            for c in categories.values { byID[c.id] = c }
            let all = Array(byID.values)

            let id = CCAskNotifyPolicy.identifier(room: room)
            let title = CCAskNotifyPolicy.title(room: room)
            let body = CCAskNotifyPolicy.body(wait: text)
            let texts = choices.map(\.text)
            print("[CCAskNotifier] 发 \(room)：\(body)（\(choices.map(\.short).joined(separator: " / "))）")
            Task {
                await Self.deliver(categories: all, id: id, title: title, body: body, categoryID: catID,
                                   room: room, texts: texts)
            }
        }

        /// 真正跟系统打交道的那一段。**`nonisolated static`、参数全是 Sendable 的值**：
        /// `UNNotificationCategory` / `UNMutableNotificationContent` / `UNNotificationRequest` 都在这里现建、
        /// 只在这里用，不跨隔离边界（理由见 `categories` 的注释）。
        nonisolated private static func deliver(categories: [CategorySpec], id: String, title: String, body: String,
                                                categoryID: String?, room: String, texts: [String]) async {
            let center = UNUserNotificationCenter.current()
            if let categoryID {
                // 不带 `.foreground`：点了不拉起 app，在后台发完就完。
                center.setNotificationCategories(Set(categories.map { c in
                    UNNotificationCategory(
                        identifier: c.id,
                        actions: c.actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: []) },
                        intentIdentifiers: [], options: [])
                }))
                // 回读一次当屏障：注册是异步的，紧接着 add 的话通知偶尔会不带按钮。
                let registered = await center.notificationCategories()
                if !registered.contains(where: { $0.identifier == categoryID }) {
                    print("[CCAskNotifier] ⚠️ category \(categoryID) 还没注册上，这条通知可能不带按钮")
                }
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let categoryID { content.categoryIdentifier = categoryID }
            content.threadIdentifier = id
            var info: [String: Any] = [CCAskNotifyPolicy.roomKey: room]
            if !texts.isEmpty { info[CCAskNotifyPolicy.textsKey] = texts }
            content.userInfo = info
            // 同一个 identifier：新的顶掉这个房间之前那条，不堆通知中心。
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            } catch {
                print("[CCAskNotifier] 发不出去（权限没给？）：\(error)")
            }
        }

        private func remove(room: String) {
            let id = CCAskNotifyPolicy.identifier(room: room)
            categories[room] = nil
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [id])
            center.removePendingNotificationRequests(withIdentifiers: [id])
            print("[CCAskNotifier] 撤 \(room)")
        }

        // MARK: - 点了通知

        /// 用户点了通知（按钮或通知本身）。转发器已经在系统的队列上把它抠成了纯字符串，这里已在主线程。
        private func handle(_ tap: CCAskNotifyDelegate.Tap) async {
            switch tap {
            case let .reply(room, text): await Self.answer(room: room, text: text)
            case let .open(room): Self.open(room: room)
            }
        }

        /// 通知上的回答按钮：**跟 app 主界面、锁屏卡片走同一个出口**（槽位的 `CCQuickReplySender.send`）。
        /// 发出去之后 `repliedAt` 变了 ⇒ 观察回调 ⇒ Policy 判「回答过了」⇒ 撤（这条点完系统本来也收起了）。
        private static func answer(room: String, text: String) async {
            guard let slot = shared.rooms?.slots.first(where: { $0.name == room }) else {
                print("[CCAskNotifier] 回答：房间 \(room) 不在（app 可能刚被系统拉起，还没连）")
                notifyFailure(room: room, text: text, reason: "房间还没连上")
                return
            }
            let ok = await slot.quickReply.send(text)
            print("[CCAskNotifier] 回答 \(room)：\(text) → \(ok ? "已发出" : (slot.quickReply.lastError ?? "失败"))")
            // 点按钮时通知已经被系统收起了，用户以为答完了 —— 没发出去必须再告诉他一声，
            // 不然 bot 一直等、人一直以为答过了。
            if !ok { notifyFailure(room: room, text: text, reason: slot.quickReply.lastError ?? "没发出去") }
        }

        /// 「没发出去」补一条（同一个 identifier，顶掉这个房间那条问题；不带按钮 —— 点开 app 再答）。
        private static func notifyFailure(room: String, text: String, reason: String) {
            let id = CCAskNotifyPolicy.identifier(room: room)
            Task {
                await deliver(categories: [], id: id, title: "\(room)：回复没发出去",
                              body: "「\(text)」—— \(reason)。打开 app 再回一次。", categoryID: nil,
                              room: room, texts: [])
            }
        }

        /// 点的是通知本身：系统把 app 拉到前台，顺手切到那个房间。
        private static func open(room: String) {
            shared.rooms?.activate(room)
        }
    }

    /// 收通知点击的转发器。
    ///
    /// ## 为什么单独一个 `nonisolated` 类型（Swift 6）
    ///
    /// 系统在**自己的后台队列**上调 delegate 回调。工程开着默认 MainActor 隔离 ＋ Approachable Concurrency
    /// （含「推断隔离的协议遵循」）：要是让 `CCAskNotifier`（MainActor）自己当 delegate，遵循会被推断成
    /// MainActor 隔离的，回调一旦被当成 MainActor 的来跑，就会撞上「期望在主线程」的断言
    /// （Xcode 16 起 `UNUserNotificationCenterDelegate` 最常见的那个崩溃）。
    /// ⇒ 跟 `CCAvatarDelegate` / `CCBotStatus.Delegate` 同一个套路：一个只做转发的 `NSObject`，
    /// 这里更进一步整个类型标 `nonisolated`，遵循也就不带隔离。回调里先把 action id、userInfo 里的
    /// 房间和句子抠成 String（`UNNotificationResponse` 不是 Sendable，不带过隔离边界），
    /// 再交给一个 `@Sendable` 闭包，由它自己 `await` 进 MainActor。
    ///
    /// 用 async 版回调：系统等它返回才算处理完 —— 后台被拉起时也会给够时间把那句发出去。
    nonisolated final class CCAskNotifyDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        /// 点了什么，抠成纯值。
        enum Tap: Sendable {
            /// 点了回答按钮：给这个房间发这句完整原句。
            case reply(room: String, text: String)
            /// 点了通知本身：app 被拉到前台，切到这个房间。
            case open(room: String)
        }

        private let onTap: @Sendable (Tap) async -> Void

        init(onTap: @escaping @Sendable (Tap) async -> Void) {
            self.onTap = onTap
            super.init()
        }

        // ## completionHandler 必须回主线程调（2026-10-06 真机崩溃）
        //
        // 原来写的是 async 版 `didReceive(_:) async`。编译器替它生成的 `@objc` 包装会在 async 体
        // 跑完的**那个线程**上调系统给的 completionHandler —— 而这个类是 nonisolated，跑在后台线程。
        // UIKit 的那个 completionHandler 里要更新快照 / 状态恢复，断言必须在主线程：
        //   'NSInternalInconsistencyException', reason: 'Call must be made on main thread'
        //   ← -[UIApplication _updateSnapshotAndStateRestorationWithAction:…]
        //   ← @objc closure #1 in CCAskNotifyDelegate.userNotificationCenter(_:didReceive:)
        // 表现：点通知上的按钮，回答已经发出去了，app 随即崩溃退出（Chris 复现三次，tommy 挂 console 抓到栈）。
        // ⇒ 手写 completionHandler 版：先在当前线程把字符串抠出来，Task 里把事办完，
        //    **最后显式回到 MainActor 再调 completionHandler**。
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let action = response.actionIdentifier
            let info = response.notification.request.content.userInfo
            let tap: Tap?
            if let r = CCAskNotifyPolicy.reply(userInfo: info, actionID: action) {
                tap = .reply(room: r.room, text: r.text)
            } else if action == UNNotificationDefaultActionIdentifier,
                      let room = CCAskNotifyPolicy.tappedRoom(userInfo: info) {
                tap = .open(room: room)
            } else {
                tap = nil            // 别的（划掉、别家的通知）不管
            }
            // completionHandler 不是 Sendable；包一层再带进 Task（只在主线程上调它一次）。
            let done = CompletionBox(completionHandler)
            let onTap = self.onTap
            Task {
                if let tap { await onTap(tap) }
                await MainActor.run { done.call() }
            }
        }

        /// 把系统给的 completionHandler 带过隔离边界。只调一次、只在主线程上调（见上）。
        nonisolated private final class CompletionBox: @unchecked Sendable {
            private let fn: () -> Void
            init(_ fn: @escaping () -> Void) { self.fn = fn }
            func call() { fn() }
        }

        // 不实现 `willPresent`：app 在前台时系统默认不弹横幅 —— 正是要的（我们本来也只在后台发；
        // 万一发出的那一刻刚好切回前台，人已经在 app 里看得到按钮了）。跟装 delegate 之前的行为一致。
    }

#endif
