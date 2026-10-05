// 锁屏 / 灵动岛实时活动：**app 和扩展两边都要认识的类型**。
//
// 两个 target 都编这个文件（pbxproj 里 "Exceptions for "VoiceAgent" folder in
// "CloseCrabActivity" target" 那条把它从 app 目录共享给扩展）。所以：
//
// - 整个文件包在 `#if os(iOS) && canImport(ActivityKit)` 里 —— app 还要编 macOS 和
//   visionOS，那两边没有实时活动（visionOS 上 `os(iOS)` 为假）。
// - **不碰 LiveKit / CCRooms / CCStore**，扩展不链 LiveKit。
//
// ## 按钮的 intent 为什么在扩展里也有一份、却不在扩展里执行
//
// Apple 文档（Adding interactivity to widgets and Live Activities）原话：
// 「If you adopt the `LiveActivityIntent` or `AudioPlaybackIntent` protocol, the system runs
//  the app intent in the app's process. Make sure to add your custom app intent to your app target.」
//
// ⇒ `perform()` 在 **app 进程**里跑（app 没在跑时系统会在后台把它拉起来，不打开界面）。
//    扩展这边只需要这个类型能被 `Button(intent:)` 引用 —— 所以类型两边都编，
//    但真正干活的代码（找房间、调 `CCPlaybackRemote`）只在 app 里：通过
//    `CCLiveActivityBridge.handler` 这个钩子，app 启动时由 `CCLiveActivity.attach` 装上，
//    扩展里它永远是 nil（也永远不会在扩展里被调到）。
//
// ⚠️ 被系统在后台拉起来的那种情况（app 原本没在跑）：这时一个房间都没连，钩子里找不到
//    播放器，按钮什么都不做 —— 正确的行为，而且卡片本来也该在 app 死掉时过期了。

#if os(iOS) && canImport(ActivityKit)

    import ActivityKit
    import AppIntents
    import Foundation

    /// 实时活动的「静态」那一半。**故意是空的**：卡片跟着当前房间走（Chris 2026-10-05），
    /// 房间名会变，所以连房间名也放在 `ContentState` 里，这里没有任何一开卡就定死的东西。
    ///
    /// `nonisolated`：工程默认 MainActor 隔离，而 ActivityKit 在自己的线程上编解码这两个类型；
    /// 不标的话 Codable 的合成实现是 MainActor 隔离的。
    nonisolated struct CCLiveActivityAttributes: ActivityAttributes {
        typealias ContentState = CCLiveActivityState
    }

    // MARK: - 按钮

    nonisolated enum CCLiveActivityAction: String, Sendable {
        /// 在播就停、停着就继续、播完了就重播（跟捏 AirPods 同一个判定，见 `CCPlaybackRemote.smartToggle`）。
        case toggle
        /// 重播当前这一段。
        case replay
    }

    /// 按钮在 app 进程里落到哪。**只有 app 会给它赋值**（`CCLiveActivity.attach`）。
    @MainActor
    enum CCLiveActivityBridge {
        static var handler: (@MainActor (CCLiveActivityAction, String) async -> Void)?
        /// 快捷回复（房间, 那句话）。跟 `handler` 分开：它带一段文字，塞不进上面那个 rawValue 枚举。
        static var replyHandler: (@MainActor (String, String) async -> Void)?
    }

    /// 暂停 / 继续。
    struct CCLiveActivityToggleIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "暂停或继续"
        /// 只给卡片上的按钮用，不进快捷指令 / Spotlight —— 那里没有「哪个房间」的上下文。
        static var isDiscoverable: Bool { false }

        @Parameter(title: "房间")
        var room: String

        init() {}

        init(room: String) {
            self.room = room
        }

        @MainActor
        func perform() async throws -> some IntentResult {
            await CCLiveActivityBridge.handler?(.toggle, room)
            return .result()
        }
    }

    /// 重播刚才那一段。
    struct CCLiveActivityReplayIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "重播"
        static var isDiscoverable: Bool { false }

        @Parameter(title: "房间")
        var room: String

        init() {}

        init(room: String) {
            self.room = room
        }

        @MainActor
        func perform() async throws -> some IntentResult {
            await CCLiveActivityBridge.handler?(.replay, room)
            return .result()
        }
    }

    /// 快捷回复：「没问题，请继续」「按照你的想法来」（`CCLiveActivityState.quickReplies`）。
    /// bot 在等你回话时代替暂停 / 重播出现在卡片上。
    ///
    /// 点下去在 **app 进程**里执行（理由见文件头），**走 app 本来的文字通道**：
    /// 跟聊天框同一个 `session.send(text:)`（LiveKit 文本流 `lk.chat`）。2026-10-05 起
    /// `lk.chat` 由 bot 本体（房间里的 `<房间名>-speaker`）接收、注入 bot 自己的对话；
    /// 语音助手不再接。所以这里不另起任何 RPC —— 实时活动只是复用「给 bot 发文字」这个能力。
    /// `text` 是完整原句（不是按钮上的简写）。
    struct CCLiveActivityQuickReplyIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "快捷回复"
        static var isDiscoverable: Bool { false }

        @Parameter(title: "房间")
        var room: String

        @Parameter(title: "回复")
        var text: String

        init() {}

        init(room: String, text: String) {
            self.room = room
            self.text = text
        }

        @MainActor
        func perform() async throws -> some IntentResult {
            await CCLiveActivityBridge.replyHandler?(room, text)
            return .result()
        }
    }

#endif
