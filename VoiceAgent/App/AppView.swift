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
        /// Mac：**波形在上、字幕在下，不是二选一。**
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
        /// ## ⛔ 第一版做成了**左右分**，那是错的
        ///
        /// Chris 2026-09-21：「点了聊天按钮以后，它把中间的显示窗劈成了左右两半。
        /// 我以为不应该是这样，应该……上边是活动的波形图，下边放聊天的内容窗口，
        /// 大概 1/3 2/3 这么分。」
        ///
        /// 他是对的，理由是**这两块东西对空间的需求方向相反**：
        ///
        /// | | 要什么 | 不要什么 |
        /// |---|---|---|
        /// | 波形 | 一条**横向**带子，宽一点更好看 | **高度** —— 柱子再高也不多给信息 |
        /// | 字幕 | **宽度**（一行能放下一句话）＋ 高度（看得见上下文） | —— |
        ///
        /// 左右分割**把两者都搞坏了**：波形被压成窄条、柱子挤在一起；
        /// 字幕被压成窄栏，一句话折三行，读起来像在看手机竖屏。
        /// 上下分割则各得其所 —— 波形拿全宽但只占一条，字幕拿全宽又拿到高度。
        ///
        /// ⇒ 一般化：**分割方向该由「谁需要哪个维度」定，不是由「有两块东西」定。**
        /// 我第一版是看到「两块内容」就想到并排，没问它们各自要什么。
        ///
        /// ## 为什么用 `VSplitView` 而不是 `VStack`
        ///
        /// 分隔条可以拖 —— **比例是用户的决定不是我的**。
        /// 1/3 : 2/3 只是个起手，有人想把字幕拉满，有人只想留两行瞄一眼。
        ///
        @ViewBuilder
        private func macInteractions() -> some View {
            if chat {
                VSplitView {
                    VoiceInteractionView()
                        // 上面那条给约 1/3。**minHeight 不能太小** ——
                        // 低于这个数柱子就挤成一排点，那还不如不显示。
                        .frame(minHeight: 150, idealHeight: 220, maxHeight: .infinity)

                    VStack(spacing: 0) {
                        // ⚠️ 这里**不用 `TextInteractionView`**。那个组件里还带了
                        //    一份参与者头像（`participants()`）—— 在手机上它是必要的，
                        //    因为切过去之后波形那一屏就看不见了。
                        //    Mac 上波形就在上面，下面再放一份头像是同一件事说两遍。
                        ChatView()
                            .blurredTop()
                        ChatInputView(keyboardFocus: _keyboardFocus)
                    }
                    // 下面那块给约 2/3，而且它是**该优先长的那一块** ——
                    // 窗口拉高时多出来的空间该给字幕，不该给波形
                    //（波形高一点不多给任何信息）。
                    .frame(minHeight: 220, maxHeight: .infinity)
                }
            } else {
                // 字幕收起来时波形独占整块，跟原来一样。
                VoiceInteractionView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
