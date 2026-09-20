import SwiftUI

extension EnvironmentValues {
    @Entry var voiceEnabled: Bool = true
    @Entry var videoEnabled: Bool = true
    @Entry var textEnabled: Bool = true
    @Entry var namespace: Namespace.ID? // don't initialize outside View

    /// 几何动画 id 的分区前缀 —— **每一页一个，值是房间名**。
    ///
    /// ## ⚠️ 为什么非有不可
    ///
    /// `matchedGeometryEffect` 的 id 只在 namespace 里唯一，而这个 app 的
    /// namespace **只有一个，在 `CCRootView` 的最外层**（那是故意的：两端落在
    /// 不同 namespace 里会直接崩）。
    ///
    /// 同时，页面是 `TabView(.page)`，**横滑时相邻页同时在场**，每页都是一整个
    /// `AppView`。于是 `"agent"` / `"camera"` / `"screen"` 这三个 id 会被
    /// N 个页面同时认领 —— 同一个 group 里多个 `isSource: true`，
    /// SwiftUI 对此的行为是未定义的。
    ///
    /// 上游 starter 是单房间，一个 id 只有一个主；多房间是我们加的，
    /// **这三个 id 是从那时起就一直撞着的**，不是哪次改动引入的。
    ///
    /// 空串是单房间/桌面端的退化情况，此时没有第二个页面，不会撞。
    @Entry var geoScope: String = ""
}
