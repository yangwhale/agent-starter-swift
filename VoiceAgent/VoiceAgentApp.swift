import LiveKit
import SwiftUI

@main
struct VoiceAgentApp: App {
    /// 多房间连接层。连接、本地媒体、音频选项、麦克风策略现在**每个房间各一份**，
    /// 由 `CCRoomSlot` 持有 —— 上游 starter 在这里各建一个，那是单房间时代的写法。
    private let rooms = CCRooms()

    /// 深浅色三档。要订阅 —— 在设置里拨了开关得立刻翻过来。
    ///
    /// 用 `@StateObject` 而不是 `@ObservedObject`：`App` 不像 View 那样会被
    /// 反复重建，`@ObservedObject` 在这一层的行为没有被文档明确保证。
    /// 包的是单例，`wrappedValue` 那个 autoclosure 只求值一次也无所谓。
    @StateObject private var config = CloseCrabConfig.shared

    init() {
        // 手写体自己注册一次兜底。**Font.custom 找不到字体时不报错、直接退回
        // 系统字体**，所以漏打包只会表现成「开关拨了没反应」，没有任何日志。
        // 这一步顺便把结果记下来给设置页显示。
        CCHandFont.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            CCRootView(rooms: rooms)
                // 挂在 WindowGroup 的根上而不是 CCRootView 内部：
                // sheet 是另起一棵视图树的，挂在里层的话设置页、房间抽屉、
                // 诊断页**不会跟着变** —— 主界面深色、弹出来的表单浅色。
                .preferredColorScheme(config.appearance.colorScheme)
                // 只要说和听。
                // 摄像头和屏幕共享关掉：我们的 agent 是 Gemini Live 的语音链路，
                // 收到视频轨也没人看，留着只会在控制栏上多两个按错就要重连的按钮。
                .environment(\.voiceEnabled, true)
                .environment(\.videoEnabled, false)
                // 文字这一路留着 —— 它同时是**字幕**：控制栏上那个聊天按钮打开的
                // 就是转写记录，出问题时想知道「它到底听成了什么」全靠它。
                .environment(\.textEnabled, true)
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 900)
        #endif
        #if os(visionOS)
        .windowStyle(.plain)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1500, height: 500)
        #endif
    }
}
