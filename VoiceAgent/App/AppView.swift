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
                    // 播放控制。**跟服务端那个播放器是同一个** ——
                    // 手机上按暂停，飞书卡片的进度条会跟着停。
                    //
                    // ⚠️ 显示条件是 `isSpeaking || isActive`，两个都要：
                    //   · `isSpeaking` 负责**把它叫出来** —— `isActive` 要靠轮询才知道，
                    //     而轮询只在这条栏出现之后才开，光靠它会互相等着谁都不出现
                    //   · `isActive` 负责**让它留住** —— 暂停之后 `isSpeaking` 就假了，
                    //     但播放器还咬着那段音频，这时候正是最需要「继续」那颗按钮的时刻
                    .overlay(alignment: .bottom) {
                        if slot.isSpeaking || slot.playback.isActive {
                            CCPlaybackBar(remote: slot.playback)
                                .padding(.bottom, CC.Space.snug)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .ccAnimation(.default, value: slot.isSpeaking)
                    .ccAnimation(.default, value: slot.playback.isActive)
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
        /// Mac：**聊天占满整块，波形浮在它上面那层。**
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
        /// ## ⛔ 前两版都是「分割」，两版都错
        ///
        /// **第一版左右分。** Chris 2026-09-21：「它把中间的显示窗劈成了左右两半，
        /// 我以为不应该是这样。」他是对的 —— 这两块对空间的需求方向相反：
        ///
        /// | | 要什么 | 不要什么 |
        /// |---|---|---|
        /// | 波形 | 一条**横向**带子，宽一点更好看 | **高度** —— 柱子再高也不多给信息 |
        /// | 字幕 | **宽度**（一行放得下一句话）＋ 高度（看得见上下文） | —— |
        ///
        /// 左右分把两者都搞坏了：波形压成窄条，字幕压成窄栏、一句话折三行。
        ///
        /// **第二版上下分（`VSplitView`），也不对，而且它还坏了** ——
        /// 下面那格整块是空白，输入框被顶到看不见的地方去了。
        ///
        /// ⚠️ 我**没有去追第二版为什么空**，因为承载它的那个布局整个被删掉了。
        /// 但**导致它的那个条件我补上了**（见下面 `ChatView` 那行的
        /// `maxHeight: .infinity`）：在一个高度受限的容器里，
        /// 一个 `ScrollView` 加一个固定高度的输入框，如果不显式说清
        /// 「谁吃掉剩余空间」，SwiftUI 不保证把输入框留在可见范围内。
        ///
        /// ## 第三版：**不分割，叠起来**
        ///
        /// Chris：「你就把屏都占，然后那个说话波动那个柱状图就飘在最上面的图层就行。
        /// 就相当于我的聊天窗口就变成了那个说话显示波动柱状图的背景。」
        ///
        /// 这个想法比我前两版都好，因为它**取消了那道选择题**。
        /// 分割一定要回答「各给多少」，而这个问题本身是坏的：
        /// 波形是个**几十像素高的小东西**，给它一格是浪费，给它一条又显得寒酸。
        /// 叠起来之后它不占布局空间，字幕拿到整块，**两边都不用让**。
        ///
        /// ⇒ 一般化：**「两块内容怎么放」先问它们是不是真的在抢空间。**
        /// 前两版我一直在挑分割方向，没退一步问「为什么要分」。
        ///
        /// ## `allowsHitTesting(false)` 是必须的
        ///
        /// 浮层盖着整块聊天区。不关掉命中测试的话，中间那片会把滚动和选中全吃掉 ——
        /// 表现是「聊天划不动」，而且看不出是被一个透明的东西挡着。
        ///
        /// 代价：浮层里那个**切换摄像头**的小按钮在字幕打开时点不到。
        /// 可接受 —— 它只在「摄像头开着」**且** `canSwitchCamera` 为真时才存在，
        /// 而 Mac 上通常只有一个摄像头。真要用，关掉字幕即可。
        @ViewBuilder
        private func macInteractions() -> some View {
            if chat {
                ZStack {
                    VStack(spacing: 0) {
                        // ⚠️ 这里**不用 `TextInteractionView`**。那个组件里还带了
                        //    一份参与者头像（`participants()`）—— 手机上它是必要的，
                        //    因为切过去之后波形那一屏就看不见了。
                        //    Mac 上波形就浮在上面，再放一份是同一件事说两遍。
                        ChatView()
                            .blurredTop()
                            // **显式声明「剩下的空间归我」**。不写这行的话，
                            // 这个 `ScrollView` 和下面固定高度的输入框之间
                            // 没人规定谁让谁 —— 第二版就是这么把输入框顶没的。
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        ChatInputView(keyboardFocus: _keyboardFocus)
                    }

                    // 浮在最上层。不占布局空间，所以上面那块是**整块**不是剩下的一块。
                    VoiceInteractionView()
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
