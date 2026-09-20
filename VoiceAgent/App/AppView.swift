import LiveKit
import SwiftUI

/// **一个房间的内容页** —— 分页器里的一页。
///
/// 它曾经是整屏（自带方块行、控制栏、启动页分支）。改多房间横滑之后，
/// 那些「不该跟着页面走」的东西全提到了 `CCRootView`：
/// 方块行要常驻（否则滑动时它自己也在重建），控制栏和说话条要常驻
/// （底部两条跟着内容一起横移，看着像整个 app 在漂）。
///
/// 留在这儿的只有**真正属于这个房间**的东西：它的音频可视化、
/// 它的字幕、它的摄像头预览。每一页在自己子树里注入自己槽位的环境对象，
/// 所以这里读到的 `session` 永远是本页那个房间 —— 哪怕它此刻不是当前页。
struct AppView: View {
    /// 这一页的槽位。**显示状态一律读它的镜像**，不读 `session` ——
    /// `@EnvironmentObject` 会订阅 Session 的全部变化（实测峰值 306 次/秒）。
    @Environment(CCRoomSlot.self) private var slot
    @EnvironmentObject private var localMedia: LocalMedia

    /// 字幕开关。**由 chrome 持有**，跨房间共享，所以这里是只读的值不是 `@State`。
    let chat: Bool
    @FocusState.Binding var keyboardFocus: Bool

    var body: some View {
        Group {
            if slot.isConnected {
                interactions()
                    // 房间成员条挂在**这一页**的顶上，不提到 chrome 里 ——
                    // 每页的成员不一样，跟着页面走才对得上。
                    //
                    // ⚠️ 这是 `overlay`，**不占位置**。任何顶对齐的主画面内容
                    //    都会被它盖住，那种内容要自己让开 `CCRosterRow.height`。
                    .overlay(alignment: .top) { CCRosterRow() }
            } else {
                notConnected()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ccAnimation(.default, value: slot.isConnected)
        .ccAnimation(.default, value: localMedia.isCameraEnabled)
        .ccAnimation(.default, value: localMedia.isScreenShareEnabled)
    }

    @ViewBuilder
    private func interactions() -> some View {
        #if os(visionOS)
            VisionInteractionView(chat: chat, keyboardFocus: $keyboardFocus)
        #else
            if chat {
                TextInteractionView(keyboardFocus: $keyboardFocus)
            } else {
                VoiceInteractionView()
            }
        #endif
    }

    /// 这一页的房间还没连上。
    ///
    /// 滑到一个没连上的房间时必须有东西，不能是一片黑 —— 黑屏会让人以为
    /// 滑坏了。但也**不要在这里放「连接」按钮**：连接是整批的
    /// （`rooms.startAll()`），单独连一个会让「勾选了哪些」和「连着哪些」对不上。
    private func notConnected() -> some View {
        VStack(spacing: 3 * .grid) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 32))
                .foregroundStyle(.fg3)
            Text(verbatim: "这个房间还没连上")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.fg2)
            Text(verbatim: "挂断后重新连接会把勾选的房间一起连上")
                .font(.system(size: 12))
                .foregroundStyle(.fg3)
                .multilineTextAlignment(.center)
        }
        .padding(6 * .grid)
    }
}
