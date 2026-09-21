#if os(macOS)

    import SwiftUI

    /// 菜单栏常驻项。
    ///
    /// ## 为什么 Mac 上非有不可
    ///
    /// iOS 的模型是「打开 app → 用 → 退出」；Mac 的模型是**它一直在那儿**。
    /// 窗口该能关掉而助手还活着 —— 关窗就断线的语音助手，等于每次用都要重连。
    ///
    /// 菜单栏这一条同时解决三件事：
    /// 1. **状态可见** —— 现在连的哪个房间、它是不是在说话，扫一眼图标就知道
    /// 2. **不用开窗切房间** —— 菜单里直接点
    /// 3. **窗口关了也还在** —— 配合全局热键（`CCMacHotkey`）就是完整形态
    struct CCMenuBarLabel: View {
        let rooms: CCRooms

        var body: some View {
            // 只用 SF Symbol，不画自定义图形：菜单栏会跟着深浅色和「减少透明度」
            // 等辅助功能设置变，自己画的东西在那些情况下会糊。
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel(Text(verbatim: accessibility))
        }

        private var symbol: String {
            guard let slot = rooms.active else { return "waveform.slash" }
            if slot.isMuted { return "mic.slash" }
            if slot.isSpeaking { return "waveform" }
            return "waveform.circle"
        }

        private var accessibility: String {
            guard let slot = rooms.active else { return "未连接" }
            if slot.isSpeaking { return "\(slot.name) 正在说话" }
            return slot.name
        }
    }

    /// 菜单栏点开之后的内容。
    struct CCMenuBarContent: View {
        let rooms: CCRooms
        @Environment(\.openWindow) private var openWindow
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            if let active = rooms.active {
                Text(verbatim: "当前：\(active.name)")
                Button(active.isMuted ? "取消静音" : "静音") {
                    // 走跟界面同一条路，不要在这儿另写一套开关逻辑 ——
                    // 两套状态迟早会对不上。
                    // ⚠️ 原来这里是 `active.isMuted.toggle()` —— 只翻了标记，
                    //    **音量一个字节都没动**，菜单栏这条静音一直是装饰。
                    //    改 `isMuted` 为 private(set) 就是为了让这种写法编不过。
                    active.applyMute(!active.isMuted)
                }
                Divider()
            }

            // ⌘1…⌘9 跟主窗口的快捷键是同一套，这里显示出来是为了让人**知道有**。
            // 快捷键最大的问题从来不是不好用，是没人发现它存在。
            ForEach(Array(rooms.slots.prefix(9).enumerated()), id: \.element.id) { index, slot in
                Button {
                    rooms.activate(slot.name)
                } label: {
                    Text(verbatim: slot.name == rooms.activeName ? "● \(slot.name)" : "  \(slot.name)")
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }

            Divider()
            Button("打开窗口") { openWindow(id: CCWindowID.main) }
            // 设置也放进来：**窗口关着的时候菜单栏是唯一入口**。
            // 没有这一条的话，你得先开窗、再进抽屉、再点齿轮 —— 而 Mac 上
            // 「窗口关着但助手活着」恰恰是常态。
            Button("设置…") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Button("退出") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    // ⛔ 这里原来有个 `CCRoomCommands` —— 只有 ⌘1…⌘9 的那一版。
    //    2026-09-21 并进了 `CCMacCommands.swift` 的 `CCRoomMenuCommands`
    //    （多了 ⌘K 去哪个房间、⌘⇧M 静音），那边是唯一一份。
    //    「必须是 View 不能直接在 .commands 里展开」那条坑记在那个文件里。

#endif

/// 主窗口 id。`openWindow(id:)` 要靠它把关掉的窗口叫回来。
///
/// **放在 `#if` 外面**：`VoiceAgentApp` 里 `WindowGroup(id:)` 是全平台共用的
/// —— `#if` 不能把 `WindowGroup {` 的花括号劈开，所以 id 也不能只给 macOS。
enum CCWindowID {
    static let main = "cc.main"
    /// 诊断窗口。**Mac 上它是独立窗口不是 sheet** —— 仪表盘的用法是
    /// 「一边看它一边操作主窗口」，盖成一张纸就只能二选一。
    static let diagnostics = "cc.diagnostics"
}
