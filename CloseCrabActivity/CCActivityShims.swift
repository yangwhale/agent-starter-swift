import SwiftUI

// 共享过来的 `CCMetalGlow.swift` 里，金属渐变挂着一句 `.ccAnimation(_:value:)`。
// 那个修饰符在 app 里住在 `CCTheme.swift`，背后连着 `CCMotionPolicy` / `CC.Motion` 一整套 ——
// 为了一句动画把它们全拖进扩展不值。这里给扩展单独垫一个同名同签名的版本。
//
// **它什么都不做**：实时活动里不能跑自定义动画（系统只在内容更新时做自己的过渡），
// 脸是按心情选定的一帧静态姿态（方案页定的）。
//
// ⚠️ 只在扩展 target 里编（这个目录只属于扩展）—— app 里有真的那一份，两份不会同时出现。
extension View {
    func ccAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        self
    }
}
