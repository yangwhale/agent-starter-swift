import LiveKit
import SwiftUI

@main
struct VoiceAgentApp: App {
    /// 多房间连接层。连接、本地媒体、音频选项、麦克风策略现在**每个房间各一份**，
    /// 由 `CCRoomSlot` 持有 —— 上游 starter 在这里各建一个，那是单房间时代的写法。
    private let rooms = CCRooms()

    init() {}

    var body: some Scene {
        WindowGroup {
            CCRootView(rooms: rooms)
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
