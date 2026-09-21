#if os(macOS)

    import SwiftUI

    /// 菜单命令要够得着窗口里的状态 —— 这是官方给的那条路。
    ///
    /// ## 为什么不能直接从 `.commands { }` 里改 View 的 `@State`
    ///
    /// `App` 不是 View，菜单闭包拿不到 `CCRootView` 的任何 `@State`。
    /// 自己造一个单例当中转也能通，但那样**多窗口的时候就错了** ——
    /// 单例只有一份，⌘K 会作用到「最后一个设置它的窗口」，而不是**当前这个**。
    ///
    /// `focusedSceneValue` 解决的正是这件事：值跟着**当前获得焦点的那个场景**走。
    /// 现在只有一个窗口，看不出差别；等做了「一个房间一个窗口」，
    /// 这个选择就是对错之分。先用对的那条，省得到时候整片重写。
    struct CCRoomDrawerKey: FocusedValueKey {
        typealias Value = Binding<Bool>
    }

    /// 字幕（转写）面板开着没有。同样跟着焦点窗口走。
    struct CCChatVisibleKey: FocusedValueKey {
        typealias Value = Binding<Bool>
    }

    extension FocusedValues {
        /// 「把房间抽屉打开」。当前窗口自己挂上来。
        var ccRoomDrawer: Binding<Bool>? {
            get { self[CCRoomDrawerKey.self] }
            set { self[CCRoomDrawerKey.self] = newValue }
        }

        /// 字幕面板开关。
        var ccChatVisible: Binding<Bool>? {
            get { self[CCChatVisibleKey.self] }
            set { self[CCChatVisibleKey.self] = newValue }
        }
    }

    /// 「通话」菜单 —— 挂断、字幕、诊断。
    ///
    /// ## 为什么这些非进菜单不可
    ///
    /// 它们在界面上都已经有按钮了（控制栏那一排），所以「功能已经有了」。
    /// 但在 Mac 上**菜单栏是这个 app 对用户的 API** ——
    /// 不在菜单里的功能，老手会当它不存在，也永远不会发现它有快捷键。
    ///
    /// 换句话说：控制栏那排按钮解决的是「能不能做」，
    /// 菜单解决的是「**知不知道能做、以及不用鼠标怎么做**」。
    /// 这两件事在手机上是一回事，在 Mac 上不是。
    struct CCCallMenuCommands: View {
        let rooms: CCRooms
        @FocusedValue(\.ccChatVisible) private var chat
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            // ⌘T —— 字幕/转写。T = Transcript。
            Button(chat?.wrappedValue == true ? "隐藏字幕" : "显示字幕") {
                chat?.wrappedValue.toggle()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(chat == nil)

            // ⌘⌥D —— 诊断盘。它是独立窗口，不是 sheet（理由见 VoiceAgentApp）。
            Button("诊断…") { openWindow(id: CCWindowID.diagnostics) }
                .keyboardShortcut("d", modifiers: [.command, .option])

            Divider()

            // ⌘⇧H —— 挂断。**挂全部**，跟控制栏那颗一致。
            // 只挂当前那个的话，别的房间还连着、还在烧 Gemini，
            // 而界面已经回到启动页 —— 用户以为断干净了。
            //
            // 不用 ⌘W：那是「关窗口」，而 Mac 上关窗**不该**挂断
            // （菜单栏还在，助手还活着）。把这两件事绑在一起是最典型的移植味。
            Button("挂断全部") {
                Task { await rooms.endAll() }
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(rooms.active == nil)
        }
    }

    /// 「房间」菜单里的全部条目。
    ///
    /// ⚠️ 必须是个 `View` 而不是直接在 `.commands { }` 里展开 ——
    /// 在 App 那一层读 `rooms.slots` 拿到的是构建那一刻的快照，
    /// **房间列表异步加载完之后菜单不会刷新**（会一直是空的）。
    /// 这条坑 `CCRoomCommands` 的注释里已经记过一次，这里同理。
    struct CCRoomMenuCommands: View {
        let rooms: CCRooms
        @FocusedValue(\.ccRoomDrawer) private var drawer

        /// 往前/往后挪一个房间。**环形** —— 到头了回到另一头，
        /// 而不是「到头就不动了」。顺序浏览的用法里，走到尽头卡住
        /// 会让人以为快捷键失灵了。
        private func step(_ delta: Int) {
            let names = rooms.slots.map(\.name)
            guard names.count > 1 else { return }
            let i = names.firstIndex(of: rooms.activeName) ?? 0
            // `%` 对负数会返回负值，先加一个 count 再取模。
            let next = ((i + delta) % names.count + names.count) % names.count
            rooms.activate(names[next])
        }

        var body: some View {
            // ⌘K —— 「去哪个房间」。
            //
            // 为什么是 ⌘K：这些年它已经成了「快速跳转/命令面板」的事实标准
            // （Slack、VS Code、Linear、Notion 都是它）。用户按下去的预期是
            // 「让我搜一个东西跳过去」，而房间抽屉正好就是这个。
            Button("去哪个房间…") { drawer?.wrappedValue = true }
                .keyboardShortcut("k", modifiers: .command)
                // 抽屉是**窗口里**的东西：窗口关着的时候这一条没有意义，
                // 而 `drawer` 为 nil 恰好就代表「没有窗口在前台」。
                .disabled(drawer == nil)

            Divider()

            // ⌘⇧M 静音。**不用 ⌘M** —— 那是系统的「最小化窗口」，
            // 抢它等于把一个标准行为弄没了，而用户不会觉得是我们干的。
            Button(rooms.active?.isMuted == true ? "取消静音" : "静音当前房间") {
                guard let slot = rooms.active else { return }
                // 走跟界面同一条路。**不要在这里另写一套开关** ——
                // 菜单栏那条曾经就是只翻标记不动音量，装饰了很久没人发现。
                slot.applyMute(!slot.isMuted)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(rooms.active == nil)

            Divider()

            // ⌥↑ / ⌥↓ —— 上一个 / 下一个房间。
            //
            // Chris 2026-09-21 点名要这个（「用 Option 加上下来切换房间」）。
            // 它跟 ⌘1…⌘9 是**两种不同的用法**，不是重复：
            //   ⌘1…⌘9  我知道我要去第几个 —— **随机访问**
            //   ⌥↑ / ⌥↓ 我想挨个看看 —— **顺序浏览**
            // 房间多到记不住第几个是谁的时候，只有后者能用。
            //
            // 为什么是 ⌥ 不是 ⌘：⌘↑/⌘↓ 在 Mac 上有既定含义
            // （列表跳到首/末、Finder 进出目录），抢它会弄坏一个标准行为。
            // ⌥ 加方向键在多数 app 里是「在同级之间移动」，语义正好对上。
            Button("上一个房间") { step(-1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(rooms.slots.count < 2)
            Button("下一个房间") { step(1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(rooms.slots.count < 2)

            Divider()

            // ⌘1…⌘9 直切房间。横滑是给手指的，鼠标用户本来没有入口。
            ForEach(Array(rooms.slots.prefix(9).enumerated()), id: \.element.id) { index, slot in
                Button(slot.name == rooms.activeName ? "● \(slot.name)" : slot.name) {
                    rooms.activate(slot.name)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
    }

#endif
