import LiveKit
import SwiftUI

/// 多房间和既有界面之间的**唯一接缝**。
///
/// 整个 app 有 19 处从环境里读 `Session` / `LocalMedia` / `AudioOptions` /
/// `CCMicPolicy`。改成多房间之后，那 19 处**一处都没动** —— 因为环境里始终
/// 只注入一份，只不过它现在来自「当前选中的槽位」而不是一个全局单例。
/// 切房间时换的是注入的对象，SwiftUI 自己会重建订阅。
///
/// 这是整个改动能收敛的原因。否则就得让每个界面自己去问「我该读哪个房间」，
/// 那是把一个局部问题摊给全体。
struct CCRootView: View {
    @ObservedObject var rooms: CCRooms

    var body: some View {
        Group {
            if let slot = rooms.active {
                AppView()
                    .environmentObject(slot.session)
                    .environmentObject(slot.localMedia)
                    .environmentObject(slot.audioOptions)
                    .environmentObject(slot.micPolicy)
                    // 切房间时整棵子树重建。代价是聊天记录的滚动位置会回到顶部，
                    // 但换房间本来就是换一场对话，保留上一场的滚动位置更奇怪。
                    // 更重要的是：不加 id 的话，那些 @EnvironmentObject 换了对象
                    // 但 @State 还留着上一个房间的（比如「正在切换中」的转圈），
                    // 那种残留极难查。
                    .id(slot.name)
            } else {
                empty()
            }
        }
        .environmentObject(rooms)
    }

    /// 一个房间都没有。正常情况见不到 —— 名单空了才会（服务端 ALLOWED_ROOMS 没配）。
    /// 但不能白屏：白屏和崩溃在用户眼里是一回事。
    private func empty() -> some View {
        VStack(spacing: 4 * .grid) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 40))
                .foregroundStyle(.fg3)
            Text(verbatim: "一个房间都没有")
                .font(.system(size: 17, weight: .medium))
            Text(verbatim: "检查服务端的 ALLOWED_ROOMS，或者下拉刷新房间列表")
                .font(.system(size: 13))
                .foregroundStyle(.fg3)
                .multilineTextAlignment(.center)
        }
        .padding(8 * .grid)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bg1)
    }
}
