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
                    // 牌子 ＋ 紧贴着它下面那条状态带。
                    //
                    // ⚠️ 这是 overlay，**不占位置**（浮在主画面上）。以前状态屏
                    //    做在中间那块大屏上，于是「有数字人就放数字人、没有才放状态」
                    //    得二选一 —— 而这两样根本不冲突。挪上来之后中间还给
                    //    数字人/柱子，两边都在，顺带也不会再压到牌子上。
                    .overlay(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            CCRosterRow()
                            CCBotStatusStrip(status: slot.botStatus)
                        }
                    }
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
        #elseif os(macOS)
            macInteractions()
        #else
            // 手机上只能二选一 —— 屏幕就那么大，两样并排谁都看不清。
            if chat {
                TextInteractionView(keyboardFocus: $keyboardFocus)
            } else {
                VoiceInteractionView()
            }
        #endif
    }

    #if os(macOS)
        /// Mac：**波形和字幕并排，不是二选一。**
        ///
        /// ## 这是「大屏」真正的意思
        ///
        /// 手机上那个 `if chat { 文字 } else { 波形 }` 不是设计选择，
        /// 是**屏幕逼出来的**：两样并排谁都看不清，所以只能切。
        ///
        /// 大屏上这个约束不存在了，而切换的代价还在 —— 你想一边听它说、
        /// 一边看它把你的话听成了什么，在手机上做不到，在 Mac 上没有理由做不到。
        /// 出问题时「它到底听成了什么」正是最要紧的那个信息。
        ///
        /// 所以 ⌘T 在 Mac 上的语义也变了：**不是「换一个视图」，
        /// 是「多开/收起一块面板」**。波形一直在。
        ///
        /// ## 为什么用 `HSplitView` 而不是 `HStack`
        ///
        /// 分隔条可以拖 —— **宽度是用户的决定不是我的**。
        /// 有人想把字幕拉得很宽当聊天记录看，有人只想留一条窄的瞄一眼，
        /// 这两种用法我都猜不准，也不该猜。
        ///
        /// ## ⚠️ 一个要盯着的代价
        ///
        /// `ChatView` 是**全 app 唯一保留 `@EnvironmentObject Session` 的地方**
        /// （它显示的就是 `session.messages`，没有镜像可读）。原来那句
        /// 「只有打开字幕时它才在视图树上」在 Mac 上字面仍然成立，
        /// **但人的用法变了** —— 手机上开字幕就看不见波形，所以看完就关；
        /// Mac 上并排之后，多数人会一直开着。
        ///
        /// 也就是说：**这块面板从「偶尔挂一会儿」变成了「常驻」**，
        /// 而它订阅的是那条峰值几百次每秒的通知。
        /// 省电那一轮量的是「字幕关着」的场景，Mac 上要重新量一次。
        @ViewBuilder
        private func macInteractions() -> some View {
            HSplitView {
                VoiceInteractionView()
                    // 波形那块不能被挤没。280 是「柱子还看得出高低」的下限。
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)

                if chat {
                    VStack(spacing: 0) {
                        // ⚠️ 这里**不用 `TextInteractionView`**。那个组件里还带了
                        //    一份参与者头像（`participants()`）—— 在手机上它是必要的，
                        //    因为切过去之后波形那一屏就看不见了。
                        //    Mac 上波形就在左边，右边再放一份头像是同一件事说两遍。
                        ChatView()
                            .blurredTop()
                        ChatInputView(keyboardFocus: _keyboardFocus)
                    }
                    .frame(minWidth: 260, idealWidth: 360, maxHeight: .infinity)
                    // 拆掉/装上的时候别硬跳。用淡入淡出不用位移 ——
                    // 位移会让左边那块跟着抖，而它本来是不该动的。
                    .transition(.opacity)
                }
            }
        }
    #endif

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
