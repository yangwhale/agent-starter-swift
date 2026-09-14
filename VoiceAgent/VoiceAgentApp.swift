import LiveKit
import SwiftUI

@main
struct VoiceAgentApp: App {
    private let session: Session
    private let localMedia: LocalMedia
    private let audioOptions: AudioOptions
    private let micPolicy: CCMicPolicy

    init() {
        // The audio options panel applies its selection when the microphone
        // track is created. To guarantee that the very first captured frames
        // already use custom processing options, set them as room defaults
        // here instead, e.g.
        // RoomOptions(defaultAudioCaptureOptions: AudioCaptureOptions(echoCancellationMode: .software, ...))
        //
        // ── 和上游 starter 的区别 ──────────────────────────────────────
        // 上游这里是一个 `AgentToConnect` 枚举，在 LiveKit 官网演示 agent 和
        // LiveKit Cloud 的开发 token server 之间二选一。两个我们都不用：
        // 房间是自己的、token 也是自己签的，所以整个枚举删掉，直接换成
        // `CloseCrabTokenSource`。
        //
        // 房间**不在这里定**。Session 的 tokenOptions 是 let，定死了就换不了房间，
        // 而我们是一个 bot 一个常驻房间、要能随时切。所以房间名由 token source
        // 在每次 fetch 的时候现读设置 —— Session 只有一个，切房间不用重建。
        // `preConnectAudio: false` —— 不要连接之前就开始采集。
        //
        // ⚠️ **只改这一项不够，做不到「进房默认闭麦」。** 扒过 `Session.start()`：
        // 两条分支都会开麦，这个参数管的只是**什么时候开**，不是**开不开**。
        // 走 false 这一支时它紧接着就 `setMicrophone(enabled: true)`。
        // 所以还要 `CCMicPolicy` 在每次连上的那一刻把它按回去，两件事缺一不可。
        session = Session(
            tokenSource: CloseCrabTokenSource(),
            options: SessionOptions(
                room: Room(roomOptions: RoomOptions(
                    defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(useBroadcastExtension: true)
                )),
                preConnectAudio: false
            )
        )
        localMedia = LocalMedia(session: session)
        audioOptions = AudioOptions(localMedia: localMedia)
        micPolicy = CCMicPolicy(session: session)
    }

    var body: some Scene {
        WindowGroup {
            AppView()
                .environmentObject(session)
                .environmentObject(localMedia)
                .environmentObject(audioOptions)
                .environmentObject(micPolicy)
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
