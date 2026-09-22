import SwiftUI

/// **这块屏是宽屏形态吗。**
///
/// Chris 2026-09-22 14:12：
/// 「iPad 毕竟跟 iPhone 的屏幕是不一样的，它还是能横过来的，
///  更像是 macOS 的那个 APP 的格式。」
///
/// ## 为什么要有这个环境值，而不是各处自己判断
///
/// 改之前，「这是不是大屏」这个问题在代码里有**三个互不相同的答案**：
///
/// | 地方 | 它怎么问 | 于是 iPad 落在哪 |
/// |---|---|---|
/// | `CCShell.connected()` | `#if os(macOS)` | **手机布局** |
/// | `AppView.interactions()` | `#if os(macOS)` | **手机布局**（字幕和波形二选一） |
/// | `VoiceInteractionView` | `horizontalSizeClass == .regular` | **大屏分支** |
///
/// ⇒ 同一台 iPad，外壳按手机排、里面按大屏排。而那个大屏分支
/// （左右各钉死 200pt）**从来没有人在真机上看过** —— iPhone 永远走不到它，
/// Mac 走的是另一条路。**编译得过、测不到的死路。**
///
/// ⇒ 所以这里不是「加一个便利属性」，是**把三个答案合并成一个**。
///
/// ## 判据是宽度，不是操作系统
///
/// - **Mac 恒为真** —— 它没有窄的时候（窗口再小也是鼠标 ＋ 键盘的交互形态）
/// - **visionOS 恒为假** —— 它有自己那条 `VisionInteractionView`，不走这套
/// - **iOS 看 `horizontalSizeClass`** —— iPad 全屏（含 mini、含竖屏）是
///   `.regular`；iPhone 是 `.compact`；⚠️ **iPad 分屏/Slide Over 会变成
///   `.compact`**，那时候它就该按手机排，这正是我们想要的行为
///
/// ⇒ 一般化：**「大屏」是个尺寸问题，拿操作系统去代理它，
/// 在 iPad 上一定会错** —— 因为 iPad 两种形态都有，而 `#if` 是编译期的，
/// 它看不见用户把窗口拖成了多宽。
extension EnvironmentValues {
    @Entry var ccWide: Bool = false
}
