import SwiftUI

/// 「打开设置」在两个平台上根本不是同一件事，这里把差异收成一处。
///
/// ## 为什么不能两边都用 sheet
///
/// Mac 上设置是 `Settings {}` **场景** —— 一个独立窗口，系统自动把它接到
/// 「App 菜单 › 设置…」和 **⌘,** 上。那个快捷键是 Mac 用户的肌肉记忆，
/// 你拦不住他去按。
///
/// 所以如果界面上的齿轮按钮弹的是 sheet，就会出现**两条路通向不同的东西**：
/// 点齿轮盖一张纸，按 ⌘, 开一个窗口，两份 UI 各改各的状态。
/// 这比「只有一个入口」糟得多。
///
/// ## 为什么做成 modifier 而不是换掉按钮
///
/// 入口有三个（房间抽屉的齿轮、启动页的「设置」、菜单栏），
/// 三处各自的按钮长得完全不一样 —— 一个是 toolbar 图标，一个是胶囊文字按钮。
/// **要统一的是「弹出来的那一下」，不是按钮本身。**
/// 换成统一按钮的话，三处样式都得重做，还会把不相干的改动混进来。
///
/// 用法：调用方照旧写 `settingsPresented = true`，只把原来的
/// `.sheet(isPresented:) { CloseCrabSettingsView() }` 换成这一行。
extension View {
    func ccSettingsSheet(isPresented: Binding<Bool>) -> some View {
        modifier(CCSettingsPresenter(isPresented: isPresented))
    }
}

private struct CCSettingsPresenter: ViewModifier {
    @Binding var isPresented: Bool

    #if os(macOS)
        @Environment(\.openSettings) private var openSettings
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
            // Mac 上这个 Bool 不是「设置页开着吗」，是**一个「请打开」的脉冲** ——
            // 设置窗口的生死由系统管，我们既不知道也不该知道它关没关。
            // 所以立刻复位：不复位的话第二次点齿轮 `onChange` 不会再触发
            // （值没变），表现是「第一次能开，之后就点不动了」。
            content.onChange(of: isPresented) { _, want in
                guard want else { return }
                isPresented = false
                openSettings()
            }
        #else
            content.sheet(isPresented: $isPresented) {
                CloseCrabSettingsView()
            }
        #endif
    }
}
