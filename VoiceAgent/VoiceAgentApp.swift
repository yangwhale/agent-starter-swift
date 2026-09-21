import LiveKit
import SwiftUI

@main
struct VoiceAgentApp: App {
    /// 多房间连接层。连接、本地媒体、音频选项、麦克风策略现在**每个房间各一份**，
    /// 由 `CCRoomSlot` 持有 —— 上游 starter 在这里各建一个，那是单房间时代的写法。
    private let rooms: CCRooms

    /// 数字人开关的客户端这一半：上报「想要吗 / 看得见吗」，收服务端的结论。
    /// 在这一层接线是因为它要跟着 `scenePhase` 走 —— 而 scenePhase 的
    /// 权威来源就在这里，往下传只会让每个 View 各读一份、各判一次。
    private let avatar = CCAvatarLink.shared

    /// 深浅色三档。要订阅 —— 在设置里拨了开关得立刻翻过来。
    ///
    /// 用 `@StateObject` 而不是 `@ObservedObject`：`App` 不像 View 那样会被
    /// 反复重建，`@ObservedObject` 在这一层的行为没有被文档明确保证。
    /// 包的是单例，`wrappedValue` 那个 autoclosure 只求值一次也无所谓。
    private var config: CloseCrabConfig { .shared }

    /// app 在前台还是后台。**这是 `cc.client.visible` 的唯一来源** ——
    /// 别在下层 View 里再读一遍 scenePhase 自己判，两份判断迟早会错开。
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let rooms = CCRooms()
        self.rooms = rooms
        CCAvatarLink.shared.attach(rooms: rooms)

        // ⭐ **要在连任何房间之前。** SDK 文档明确说
        //    `isAutomaticConfigurationEnabled` 得在连接前设；而且连上的那一刻
        //    就会开一次麦（见 CCAudioSessionPolicy 的类文档），晚一步就晚了。
        #if os(iOS) || os(visionOS)
        // 两件事，**故意分开装**：
        //   install()         接管音频会话（受设置里那个开关控制，可以关掉）
        //   installRecovery() 被打断之后自己爬起来（**永远装**）
        // 它们治的是两个毛病：一个是「别占着麦」，一个是「别哑掉」。
        // 绑在一个开关上的话，关掉前者会顺手把后者也关了。
        CCAudioSessionPolicy.shared.install()
        CCAudioSessionPolicy.shared.installRecovery()
        #endif

        // 手写体自己注册一次兜底。**Font.custom 找不到字体时不报错、直接退回
        // 系统字体**，所以漏打包只会表现成「开关拨了没反应」，没有任何日志。
        // 这一步顺便把结果记下来给设置页显示。
        CCHandFont.bootstrap()
    }

    var body: some Scene {
        // 带 id：macOS 上窗口被关掉之后，菜单栏那条 `openWindow(id:)`
        // 才叫得回来（匿名 WindowGroup 叫不回）。
        // 全平台统一给 id —— `#if` 不能把 `WindowGroup {` 的花括号劈成两半，
        // 那不是合法 Swift，而两边写两份又要维护两遍。
        WindowGroup(id: CCWindowID.main) {
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
                // 进后台不等于立刻不可见 —— 去抖在 `CCVisibilityPolicy` 里，
                // 「关要慢、开要快」。这里只负责把原始相位喂进去。
                .onChange(of: scenePhase) { _, phase in avatar.note(phase: phase) }
        }
        #if os(macOS)
        // ⛔ 原来是 `900 × 900`。**正方形窗口在 Mac 上是个信号** ——
        //    它说明这个尺寸不是按内容排出来的，是随手写的。
        //    1100 × 720 大致是 3:2，跟 MacBook 屏幕一族同向，
        //    而且刚好放得下「侧栏 ＋ 内容」这个两栏结构。
        .defaultSize(width: 1100, height: 720)
        // 内容有最大宽度（`CC.Size.contentMax`），窗口拉太宽会变成
        // 中间一条、两边全是背景图。给个下限免得被压扁，上限交给用户。
        .windowResizability(.contentMinSize)
        .commands {
            // 「房间」菜单：⌘K 去哪个房间、⌘⇧M 静音、⌘1…⌘9 直切。
            // 包一层 View 才订阅得到 —— 直接在这里读 `rooms.slots`，
            // 菜单只会在 App 构建那一刻取一次值，房间列表加载完不会刷新。
            CommandMenu("房间") { CCRoomMenuCommands(rooms: rooms) }
        }
        #endif
        #if os(visionOS)
        .windowStyle(.plain)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1500, height: 500)
        #endif

        #if os(macOS)
            // ⌘, —— **Mac 用户的肌肉记忆里，设置就在这个键上。**
            //
            // 原来设置只有一个入口：房间抽屉里往下翻，点一下，弹一张 sheet。
            // 那是手机的路子。Mac 上 `Settings {}` 是一个**独立窗口** ——
            // 它跟主窗口平级，可以一直开着，也不会挡住你正在看的东西。
            //
            // ⚠️ 这个场景**必须挂在 App 这一层**。写在 View 里是没有的 ——
            //    `Settings` 是 Scene 不是 View，SwiftUI 靠它自动接上
            //    「App 菜单 › 设置…」那一条和 ⌘, 这个快捷键。
            Settings {
                CloseCrabSettingsView()
                    // 跟主窗口同一套深浅色。不加的话设置窗口会跟系统走，
                    // 出现「主界面深色、设置浅色」那种拼接感。
                    .preferredColorScheme(config.appearance.colorScheme)
            }

            // 菜单栏常驻。Mac 的模型是「它一直在那儿」，不是「打开→用→退出」——
            // 窗口该能关掉而助手还活着。详见 CCMenuBar.swift。
            MenuBarExtra {
                CCMenuBarContent(rooms: rooms)
            } label: {
                CCMenuBarLabel(rooms: rooms)
            }
        #endif
    }
}
