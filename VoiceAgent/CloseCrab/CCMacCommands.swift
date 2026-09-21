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

    extension FocusedValues {
        /// 「把房间抽屉打开」。当前窗口自己挂上来。
        var ccRoomDrawer: Binding<Bool>? {
            get { self[CCRoomDrawerKey.self] }
            set { self[CCRoomDrawerKey.self] = newValue }
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
