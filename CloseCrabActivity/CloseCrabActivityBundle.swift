import SwiftUI
import WidgetKit

/// 扩展入口。**只有一样东西：锁屏 / 灵动岛实时活动**（没有桌面小组件）。
///
/// ## 这个扩展里有什么、没什么
///
/// - 本目录（`CloseCrabActivity/`）：入口、卡片界面、一个动画垫片。
/// - 从 app 目录共享过来的（pbxproj 里 "Exceptions for "VoiceAgent" folder in
///   "CloseCrabActivity" target" 那张清单）：活脸的纯逻辑和画笔（`CCFaceMood` `CCFaceMotion`
///   `CCFaceGrokEyes` `CCPresence` `CCFaceGlyph` `CCMetalGlow`）、身份色（`CCColorPrimitives`）、
///   卡片数据（`CCLiveActivityState`）、ActivityKit 类型和按钮 intent（`CCLiveActivityAttributes`）。
/// - **没有 LiveKit**：扩展不链它，上面那些共享文件也都不碰它。往清单里加文件前先确认这一点。
/// - **读不到 app 的存储**：企业描述文件没有 App Groups。扩展知道的只有系统递过来的
///   `CCLiveActivityState` —— 所以头像只能是活脸，传的照片 / emoji 显示不了。
@main
struct CloseCrabActivityBundle: WidgetBundle {
    var body: some Widget {
        CCLiveActivityWidget()
    }
}
