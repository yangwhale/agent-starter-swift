#if os(macOS)

    import SwiftUI

    /// Mac 的房间侧栏 —— 取代 iOS 那排横滚的小方块。
    ///
    /// ## 为什么不是把方块行搬过来
    ///
    /// 方块行是**手指的形状**：横向排列、靠滑动翻页、一次只能看清两三个。
    /// 手机竖着拿，横向是唯一的富余方向，所以那么排是对的。
    ///
    /// Mac 正好反过来 —— **竖向有的是空间，横向是拿来放内容的**。
    /// 而且鼠标横向滚动本来就别扭（触控板还行，鼠标滚轮多数只有竖轴）。
    ///
    /// ## 侧栏能做而方块行做不到的那件事
    ///
    /// 竖着排，每一行就有了**第二行文字的位置**。于是：
    ///
    ///     ● jarvis      改 macOS 布局      1:24
    ///       hulk        空闲
    ///       tommy       编 HEAD            0:42
    ///
    /// **不用切过去就知道谁在忙、忙多久了。** 这是这次改造里最实在的一条：
    /// 挂五个 bot 的人，最想知道的从来不是「当前这个在干嘛」，
    /// 而是「有没有谁卡住了」。方块行给不了这个 —— 一个 54pt 的方块
    /// 放不下一句话。
    ///
    /// ## 一条克制
    ///
    /// 空闲的房间**只显示「空闲」两个字**，不显示上一轮干了什么。
    /// 五行全是文字的话，侧栏会变成一面墙，而「谁在忙」这个信号
    /// 恰恰是靠**大部分行是安静的**才跳得出来。
    struct CCMacRoomSidebar: View {
        let rooms: CCRooms
        /// 「管理房间」抽屉的开关。**由 `CCShell` 持有** —— ⌘K 走的也是它，
        /// 两个入口必须是同一个状态，否则会出现「菜单能开、按钮不能开」这种鬼。
        @Binding var roomsPresented: Bool

        var body: some View {
            List(selection: selection) {
                Section {
                    ForEach(rooms.slots) { slot in
                        CCMacRoomRow(rooms: rooms,
                                     slot: slot,
                                     isActive: slot.name == rooms.activeName,
                                     isConnecting: rooms.connecting.contains(slot.name))
                            .tag(slot.name)
                    }
                } header: {
                    Text(verbatim: "房间")
                }
            }
            .listStyle(.sidebar)
            // 侧栏该能拖宽，但不能被拖到看不见名字，也不该宽到抢内容的地方。
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
            // ⛔ **这个入口不能省。**
            //
            //    侧栏列的是「已经连上的房间」，而「要连哪几个房间」是另一件事 ——
            //    它在 iOS 上挂在右上角那颗汉堡里，而汉堡只在 `touchLayout()`。
            //    Mac 换成侧栏之后我把汉堡去掉了，**却忘了把它的职责接过来** ——
            //    结果是进了房间就再也没有地方去挑别的 bot。
            //    Chris 2026-09-21 报的第二、第三条都是这个。
            //
            //    教训：**拿 B 替换 A 时，要逐条列出 A 承担的职责，
            //    而不是只看 A 的主要用途。** 汉堡的主要用途是「看房间列表」，
            //    但它还顺带挂着「打开抽屉」这个唯一入口。
            .safeAreaInset(edge: .bottom) {
                Button {
                    roomsPresented = true
                } label: {
                    HStack(spacing: CC.Space.tight) {
                        Image(systemName: "plus.circle")
                        Text(verbatim: "管理房间…")
                        Spacer()
                        // 顺手告诉他有快捷键。快捷键最大的问题不是不好用，
                        // 是没人发现它存在。
                        Text(verbatim: "⌘K")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, CC.Space.snug)
                .padding(.vertical, CC.Space.tight)
            }
        }

        /// **不能直接 `$rooms.activeName`** —— 那样只改了个字符串，
        /// `activate()` 里「把旧房间的麦克风关掉、同步 config.room」全跳过了。
        /// 全进程只有一个采集设备，漏掉关麦就是两个房间同时开着麦。
        /// （跟 `CCRootView.pageSelection` 同一个理由，那边的注释写得更细。）
        private var selection: Binding<String?> {
            Binding(
                get: { rooms.activeName },
                set: { if let name = $0 { rooms.activate(name) } }
            )
        }
    }

    /// 侧栏里的一行。
    private struct CCMacRoomRow: View {
        /// **自己接管单击就要能切房间** —— 所以这一行需要 `rooms`。
        ///
        /// ⚠️ 当初自己接管是因为双击手势挡住了 `List` 的 selection。
        /// 双击已经删了（见 body 那段），所以**这个理由现在不成立了** ——
        /// 但先不改回去：`List(selection:)` 那条路还在（键盘上下键走的就是它），
        /// 两条并存目前没冲突，而**在同一轮里既删手势又换选中通路，
        /// 出问题就分不清是哪一下**。留成已知的可简化项。
        let rooms: CCRooms
        let slot: CCRoomSlot
        let isActive: Bool
        let isConnecting: Bool

        /// 指针悬停。**Mac 上这不是锦上添花** —— 一个鼠标划过去毫无反应的
        /// 列表，用起来的感觉是「死的」，而那个印象比布局不对更早形成。
        @State private var hovering = false
        /// 换图标选择器开着没有。
        @State private var iconPicking = false

        private var icons: CCRoomIcons { .shared }
        private var identity: Color { CCIdentityColor.color(for: slot.name) }

        var body: some View {
            HStack(spacing: CC.Space.snug) {
                avatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: slot.name)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                    Text(verbatim: statusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                trailing
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // 悬停时整行**微微**亮一点。别做强高亮 —— 选中态已经用了
            // 系统的那层蓝，两个都重的话分不出「我指着它」和「它被选中了」。
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && !isActive ? Color.primary.opacity(0.06) : .clear)
                    .padding(.horizontal, -4)
            )
            // ⭐ **只剩单击切房间。双击静音删掉了 —— 这是第四版。**
            //
            //    ## 三版的来回，理由全留着（因为每一版都是被上一版逼出来的）
            //
            //    **第一版**：只挂 `.onTapGesture(count: 2)` 静音。
            //    结果把 List 的选中点击吃掉了 —— 点别的房间切不过去。
            //    原因：`count: 2` 听起来只管双击，但手势识别器要先**等一下**
            //    看有没有第二下，那一等就把单击也拦下来了。
            //
            //    **第二版**：删掉双击，静音只留右键菜单。功能在，手感没了。
            //    Chris 要「双击 mute 还是挺好用的，弄回来」。
            //
            //    **第三版**：单击和双击都自己接管，不依赖 List 的命中测试，
            //    双击声明在单击前面（`CCRoomTileRow.gestures` 里的先例）。
            //    两个功能都在了 —— **但代价一直在那儿，只是我当时只当它是实现细节。**
            //
            //    **第四版（现在）**：Chris 2026-09-21 16:56：
            //    「双击来切换静音，让单击切换房间增加了 1 秒的延迟，
            //    没那么灵活，感觉比较卡顿，就算了。」
            //
            //    ## 我第一版就写下了这个代价，却没把它当成代价
            //
            //    上面那句「注册了双击，单击就必然被延迟」——
            //    **是我自己写的，而且写对了。** 我把它当成一条「解释为什么会冲突」
            //    的知识，用完就放下了；没想到它在冲突解决之后**依然成立**：
            //    手势不打架了，那一个时间窗还在，每一次切房间都要交这笔钱。
            //
            //    ⇒ **「为了让 A 能用而付的代价」，在 A 能用之后不会自动消失。**
            //    冲突解决 ≠ 成本消失。判据：一个权衡写进注释时，
            //    要顺带写清「谁在为它持续付钱」——
            //    这里是「每一次单击的人」，而那是最高频的操作。
            //
            //    静音现在走右边那颗按钮（单击即切）＋ 右键菜单，
            //    两个入口都不需要等时间窗。
            .onTapGesture(count: 1) {
                // 点已经选中的那个不做事 —— 避免误触时白白重连一次。
                guard !isActive else { return }
                rooms.activate(slot.name)
            }
            //
            // 右键菜单：鼠标用户的入口。手机上这些功能藏在长按里，
            // Mac 上长按不是一个存在的动作。
            .contextMenu {
                Button(slot.isMuted ? "取消静音" : "静音") {
                    slot.applyMute(!slot.isMuted)
                }
                .disabled(!slot.session.isConnected)

                Divider()

                // Chris 2026-09-21：「这个列表的小方块长按的时候
                // 也不给我激活那个换图标的功能。」
                // Mac 上长按不存在，右键才是 —— 所以入口放这儿。
                Button {
                    iconPicking = true
                } label: {
                    Text(verbatim: "换图标…")
                }
            }
            .sheet(isPresented: $iconPicking) {
                // 房间方块那套选择器，key 就是房间名。
                CCIconPickerSheet(room: slot.name)
            }
            // ⚠️ **`.combine` 不能再用了。** 它把整行压成一个元素，
            //    而行里现在有一颗**能点的按钮** —— 压扁之后 VoiceOver
            //    就摸不到它了，静音对读屏用户直接消失。
            //    `.contain` 保留子元素可达，同时行本身仍有一个概括标签。
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: "\(slot.name)，\(statusLine)"))
        }

        /// 左边那个小头像。**尺寸固定 22pt** —— 侧栏一行的高度由它定，
        /// 太大会让五个房间占掉半个侧栏。
        private var avatar: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(identity.opacity(isActive ? 0.32 : 0.16))
                if let custom = icons.image(for: slot.name) {
                    custom
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Text(verbatim: icons.icon(for: slot.name))
                        .font(.system(size: 12, weight: .semibold))
                }
                // 说话时套一圈绿 —— 跟方块那边同一个约定（所有会议软件都这么干），
                // 不在 Mac 上自创一套。
                if slot.isSpeaking {
                    // ⚠️ **必须写 `Color.ccSpeaking`，不能用打点简写。**
                    //    `ccSpeaking` 定义在 `extension Color` 上，而
                    //    `strokeBorder(_:)` 收的是 `some ShapeStyle` ——
                    //    打点简写会去 `ShapeStyle` 上找同名成员，找不到，
                    //    报的是 `type 'ShapeStyle' has no member 'ccSpeaking'`，
                    //    **完全不提「你该写全类型名」**。
                    //    仓库里其它用它的地方都在能推断出 `Color` 的位置
                    //    （三元返回值、`shadow(color:)`），所以这个形状没有先例。
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.ccSpeaking, lineWidth: 2)
                }
            }
            .frame(width: 22, height: 22)
        }

        /// 行尾：计时/转圈 ＋ **静音按钮**。
        ///
        /// 原来这里是三选一（转圈 / 静音图标 / 计时），静音那个只是**指示灯**，
        /// 切换靠双击整行。第四版把它改成了按钮 —— 见 body 里那段。
        @ViewBuilder
        private var trailing: some View {
            HStack(spacing: CC.Space.tight) {
                if isConnecting {
                    ProgressView().controlSize(.mini)
                } else if let sec = runningSeconds {
                    Text(verbatim: clock(sec))
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                muteButton
            }
        }

        /// 单击即切静音。
        ///
        /// ## 为什么是喇叭不是麦克风
        ///
        /// Chris 的原话是「放一个小麦克风的图标」，**这里故意没照做**：
        /// 这个开关管的是 `slot.applyMute`，也就是**这个房间的 bot 说的话要不要
        /// 放给我听**（拧音量 ＋ 让服务端停发那一路），跟我自己的麦克风无关。
        ///
        /// 而控制栏里**真的有**一个管自己麦克风的按钮。两处都画麦克风，
        /// 就变成「同一个图标管两件相反的事」——
        /// 那种错认不会报错，只会让人某天纳闷「我明明静音了它怎么还在听」。
        ///
        /// ⇒ **图标要跟它控制的东西一致，不跟叫法一致。**
        /// 真想要麦克风那个样子的话一句话的事，但得先确认语义没歧义。
        ///
        /// ## 为什么不是纯色圆点
        ///
        /// 一个红点的全部信息都在「红」上，色觉障碍用户看到的是个灰点。
        /// 斜杠是形状，形状自己会说话。
        ///
        /// ## 常态也占位
        ///
        /// 没静音时画的是**低透明度的喇叭**，不是留白。留白的话这颗按钮
        /// 只在静音时出现 —— 而「怎么静音」就又变成一个要靠猜的东西了。
        /// 悬停时提亮，告诉你它能点。
        private var muteButton: some View {
            Button {
                slot.applyMute(!slot.isMuted)
            } label: {
                Image(systemName: slot.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    // 只用一种颜色 ＋ 透明度分层。
                    // **不要写成 `.secondary : .tertiary` 的三元** ——
                    // 那两个是 `HierarchicalShapeStyle`，三元要求两支同类型，
                    // 得套 `AnyShapeStyle` 才编得过，而那只是为了绕类型系统，
                    // 视觉上跟直接调透明度没区别。
                    .foregroundStyle(.secondary)
                    .opacity(slot.isMuted ? 1 : (hovering ? 0.8 : 0.4))
                    .frame(width: 18, height: 18)
                    // 图标本身只有十来个点，**命中区要撑到 18pt** ——
                    // 不然得瞄准才点得中，那就跟双击一样难用了。
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!slot.session.isConnected)
            .help(slot.isMuted ? "取消静音" : "静音这个房间")
            .accessibilityLabel(Text(verbatim: slot.isMuted ? "取消静音" : "静音"))
        }

        // MARK: - 状态那一行

        /// 这个房间此刻在干什么。
        ///
        /// 规则跟 iOS 那条状态带**完全一致**（`CCBotStatusStrip.mainSummary`）：
        /// 跑着看「被派去干什么」，`act` 只在没有任务可显示时兜底。
        ///
        /// ⚠️ **空闲时不显示上一轮的摘要**，只写「空闲」。iOS 那边显示摘要是因为
        /// 那是唯一一块屏、不显示就空着；侧栏有五行，五行全挂着历史结论
        /// 会把「谁在忙」这个信号淹掉。
        private var statusLine: String {
            guard slot.session.isConnected else {
                return isConnecting ? "连接中…" : "未连接"
            }
            guard let s = slot.botStatus.snap else { return "空闲" }
            if !s.wait.isEmpty { return s.wait }      // 「等你批准方案」之类
            guard s.on else { return "空闲" }
            if !s.task.isEmpty { return s.task }
            return s.act.isEmpty ? "在忙" : s.act
        }

        /// 在忙才显示时长。**空闲时那个数是冻住的**，摆在那儿只会让人以为还在跑。
        ///
        /// ⚠️ 这里**不做本地外推**（iOS 那条状态带会）。理由：侧栏是「扫一眼」
        /// 的东西，秒级精度没意义，而为它挂一个每秒跳的定时器 ×5 行
        /// 不划算 —— 省电那一轮刚把这类东西清掉。
        private var runningSeconds: Double? {
            guard let s = slot.botStatus.snap, s.on, s.sec > 0 else { return nil }
            return s.sec
        }

        private func clock(_ t: Double) -> String {
            let n = max(0, Int(t.rounded()))
            return n < 60 ? "\(n)s" : String(format: "%d:%02d", n / 60, n % 60)
        }
    }

#endif
