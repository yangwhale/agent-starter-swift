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

    /// 这块屏是宽屏形态吗。**由 `CCShell` 算好往下发** —— 判据见 `CCLayout.swift`。
    @Environment(\.ccWide) private var wide

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
                    // ⚠️ 显示条件是**三个**，各管一段生命周期：
                    //   · `isSpeaking` 负责**把它叫出来** —— `isActive` 要靠轮询才知道，
                    //     而轮询只在这条栏出现之后才开，光靠它会互相等着谁都不出现
                    //   · `isActive`   负责**暂停期间留住** —— 暂停时 `isSpeaking` 假了，
                    //     但播放器还咬着音频，那正是最需要「继续」的时刻
                    //   · `canReplay`  负责**播完之后留住** —— 播完 fid 还在，
                    //     而「刚才那段再听一遍」是这块最高频的操作
                    .overlay(alignment: .bottom) {
                        // ⚠️ 第三个条件 `canReplay` 是 2026-09-22 补的：
                        //    播完之后 `isSpeaking` 和 `isActive` 都假了，
                        //    整条消失 —— 而那正是最想按重播的时刻。
                        //
                        // 开着文字框时**不在这儿画**，改排进聊天那一列、输入框正上方（`chatStack`）。
                        // Chris 2026-10-06：浮在底部的播放条把文字输入框盖住了。
                        if !chat { playbackBar }
                    }
                    .ccAnimation(.default, value: slot.isSpeaking)
                    .ccAnimation(.default, value: slot.playback.isActive)
                    .ccAnimation(.default, value: slot.playback.canReplay)
            } else {
                notConnected()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ccAnimation(.default, value: slot.isConnected)
        .ccAnimation(.default, value: localMedia.isCameraEnabled)
        .ccAnimation(.default, value: localMedia.isScreenShareEnabled)
    }

    /// 声波柱 / 活脸在**哪一块里居中**：整块减去底部这一截。
    ///
    /// Chris 2026-10-06 截图：开着文字框时，声波柱正好压在输入框上方的播放条上。
    /// 原因是它在整块里居中，而底部那一截（播放条 ＋ 输入框）也是整块的一部分。
    /// ⇒ 让出底部这一截再居中，柱子整体上移。**开不开文字框都让同样多**，
    ///   所以切换文字框时柱子的位置不跳（同一天的另一条要求）。
    /// 144pt ≈ 输入框一行（48 ＋ 下边距 16）＋ 播放条（两行控件约 80）。
    static let voiceBottomInset: CGFloat = 36 * .grid

    /// 播放条本体（显示条件见上面 overlay 那段注释）。
    @ViewBuilder
    private var playbackBar: some View {
        if slot.isSpeaking || slot.playback.isActive || slot.playback.canReplay {
            CCPlaybackBar(remote: slot.playback)
                .padding(.bottom, CC.Space.snug)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 开着文字框时的整块：**聊天在底层占满，波形 / 活脸浮在上面原来的位置**。
    ///
    /// 手机原来是 `if chat { TextInteractionView } else { VoiceInteractionView }` 二选一 ——
    /// 一点开文字框，活脸就缩成顶上一个小头像、跟成员条挤在一起。
    /// Chris 2026-10-06：「不管点不点文字框，脸和声波条都保持原来的位置不动，别挤上去；
    /// 它本来就是透明的，放在原位也不耽误看后面的字。」⇒ 手机也用宽屏那套「叠起来」（见下面 `wideInteractions` 的长注释）。
    ///
    /// - 浮层 `.ignoresSafeArea(.keyboard)`：键盘弹起时只有聊天那一列往上让，脸留在原位。
    /// - 播放条排在输入框正上方（不再浮在底部盖住输入框）。
    private func chatStack() -> some View {
        ZStack {
            VStack(spacing: 0) {
                ChatView()
                    .blurredTop()
                    // **显式声明「剩下的空间归我」**（理由见 `wideInteractions`）。
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(iOS)
                    .contentShape(Rectangle())
                    .onTapGesture { keyboardFocus = false }
                    #endif
                playbackBar
                ChatInputView(keyboardFocus: _keyboardFocus)
            }

            // 浮在最上层，不占布局、不吃点击（理由见 `wideInteractions`）。
            VoiceInteractionView()
                .padding(.bottom, Self.voiceBottomInset)
                .allowsHitTesting(false)
                .ignoresSafeArea(.keyboard)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func interactions() -> some View {
        #if os(visionOS)
            VisionInteractionView(chat: chat, keyboardFocus: $keyboardFocus)
        #else
            if wide {
                wideInteractions()
            } else {
                // 手机也叠起来（2026-10-06 起，见 `chatStack`）。原来是二选一：
                // 「屏幕就那么大，两样并排谁都看不清」—— 但叠起来不是并排，那条理由不成立。
                if chat {
                    chatStack()
                } else {
                    VoiceInteractionView()
                        .padding(.bottom, Self.voiceBottomInset)
                }
            }
        #endif
    }

    /// 宽屏：**聊天占满整块，波形浮在它上面那层。**
    ///
    /// **2026-09-22 之前这个函数叫 `macInteractions()`，包在 `#if os(macOS)` 里。**
    /// 于是 iPad 走的是上面那条手机分支 —— 一块 744pt 宽的屏，
    /// 硬要在「看波形」和「看字幕」之间二选一。下面那整段论证
    /// （「二选一不是设计选择，是屏幕逼出来的」）**对 iPad 一字不差地成立**，
    /// 只是当初写的时候眼里只有 Mac。
    ///
    /// ## 这是「大屏」真正的意思
    ///
    /// 手机上那个 `if chat { 文字 } else { 波形 }` 不是设计选择，
    /// 是**屏幕逼出来的**：两样并排谁都看不清，所以只能切。
    ///
    /// 大屏上这个约束不存在了，而切换的代价还在 —— 你想一边听它说、
    /// 一边看它把你的话听成了什么，在手机上做不到，在大屏上没有理由做不到。
    /// 出问题时「它到底听成了什么」正是最要紧的那个信息。
    ///
    /// 所以那颗字幕开关（Mac 上是 ⌘T，iPad 上是控制栏里那颗）语义也变了：
    /// **不是「换一个视图」，是「多开/收起一块面板」**。波形一直在。
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
    ///
    /// ⚠️ **这条代价在 iPad 上比在 Mac 上重。** 原话是「Mac 上通常只有一个
    /// 摄像头，所以 `canSwitchCamera` 基本为假，这颗按钮压根不存在」——
    /// 那是 Mac 成立的理由，**iPad 有前后两个摄像头，它是存在的**。
    /// 所以 iPad 上「开着字幕就切不了摄像头」是真会发生的。
    ///
    /// 暂时接受：这个 app 的摄像头本来就极少用（主场景是语音）。
    /// 真要修，把那颗按钮提到浮层外面，别整层关命中测试。
    ///
    /// ⇒ 记一条通用的：**把一条限制标成「可接受」时，要连它成立的前提
    /// 一起写下来。** 这里写了（「Mac 上通常只有一个摄像头」），
    /// 所以换平台时一眼就能看出前提没了 —— 没写的话它会一直被当成已解决。
    @ViewBuilder
    private func wideInteractions() -> some View {
        if chat {
            // 跟手机共用一份（`chatStack`）。⚠️ 不用 `TextInteractionView`：那个组件带一份参与者头像，
            // 波形就浮在上面时再放一份是同一件事说两遍。ChatView 那行 `maxHeight: .infinity`
            // 是「谁吃掉剩余空间」的显式声明 —— 不写的话第二版就是这么把输入框顶没的。
            chatStack()
        } else {
            // 字幕收起来时波形独占整块，跟原来一样（底部同样让出播放条那段，见 `voiceBottomInset`）。
            VoiceInteractionView()
                .padding(.bottom, Self.voiceBottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
