import SwiftUI

/// A multiplatform view that shows voice-specific interaction controls.
///
/// Depending on the track availability, the view will show:
/// - agent participant view
/// - local participant camera preview
/// - local participant screen share preview
///
/// - Note: The layout is determined by the horizontal size class.
struct VoiceInteractionView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            regular()
        } else {
            compact()
        }
    }

    /// 宽屏：波形居中，摄像头/屏幕共享在右边一栏。
    ///
    /// ## ⚠️ 这个分支原来白扔 400pt，而且没人发现
    ///
    /// 老版本是这样：
    ///
    /// ```swift
    /// Spacer().frame(width: 50 * .grid)     // 左边 200pt，纯空白
    /// AgentView()
    /// VStack { ... }.frame(width: 50 * .grid)   // 右边 200pt
    /// ```
    ///
    /// **`width:` 是固定值不是上限** —— 那 200pt 无条件占着。而右栏里那两个
    /// 视图（`ScreenShareView` / `LocalParticipantView`）在**没有对应轨道时
    /// `body` 直接什么都不返回**，也就是说常态下那是**两百点的空气**，
    /// 外加左边配重的两百点。
    ///
    /// iPad mini 竖屏逻辑宽约 744pt ⇒ 中间只剩三百多点，**比 iPhone 还窄**。
    ///
    /// ## 为什么一直没被发现
    ///
    /// 这条分支的条件是 `horizontalSizeClass == .regular` ——
    /// **iPhone 永远走不到它**，而 Mac 窗口通常很宽，400pt 看着只是「留白大方」。
    /// 唯一会难看的设备恰好是唯一没人装过的设备。
    ///
    /// ⇒ 一般化：**一个从没在真机上被看过的分支，「它编得过」是关于它的
    /// 全部已知信息。** 这类分支不会报错，只会一直错着。
    ///
    /// ## 现在的写法
    ///
    /// - 左边那个配重 **删掉**。它存在的唯一理由是跟右栏对称，
    ///   而右栏常态为空 —— 为一个不存在的东西做配重。
    /// - 右栏 `width:` 改成 `maxWidth:`（**上限**）。`VStack` 的横向理想宽度
    ///   是最宽子视图，里面什么都没有时就是 0 ⇒ 不占地方。有摄像头画面时
    ///   长到 200pt 封顶。
    /// - `AgentView` 用 `maxWidth: .infinity` 吃掉中间。空栏时它拿到整宽、
    ///   内容居中；有画面时被推开一点 —— 跟所有视频会议一个样。
    ///
    /// ⛔ **不要用 `.fixedSize` 去实现「空了就不占地」。** 那是「放弃跟父视图
    /// 协商」，视频轨道的理想宽度可能是原始分辨率，会把整行撑爆。
    private func regular() -> some View {
        HStack(spacing: CC.Space.regular) {
            AgentView()
                .frame(maxWidth: .infinity)
            VStack(spacing: CC.Space.snug) {
                Spacer()
                ScreenShareView()
                LocalParticipantView()
            }
            .frame(maxWidth: 50 * .grid)
        }
        .safeAreaPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compact() -> some View {
        ZStack(alignment: .bottom) {
            AgentView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 「按住说话」原来铺在这片中间区域上，现在挪到底部长条了 ——
            // 它用 DragGesture(minimumDistance: 0)，手指一落下就把手势吃掉，
            // 而这片区域现在要留给左右滑动切 bot，两者不能共存。
            HStack {
                Spacer()
                ScreenShareView()
                LocalParticipantView()
            }
            .frame(height: 50 * .grid)
            .safeAreaPadding()
        }
    }
}
