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

        var body: some View {
            List(selection: selection) {
                Section {
                    ForEach(rooms.slots) { slot in
                        CCMacRoomRow(slot: slot,
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
        let slot: CCRoomSlot
        let isActive: Bool
        let isConnecting: Bool

        /// 指针悬停。**Mac 上这不是锦上添花** —— 一个鼠标划过去毫无反应的
        /// 列表，用起来的感觉是「死的」，而那个印象比布局不对更早形成。
        @State private var hovering = false

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
            // 双击静音 —— 跟方块那边同一个手势，肌肉记忆通用。
            .onTapGesture(count: 2) {
                guard slot.session.isConnected else { return }
                slot.applyMute(!slot.isMuted)
            }
            // 右键菜单：鼠标用户的入口。手机上这些功能藏在长按里，
            // Mac 上长按不是一个存在的动作。
            .contextMenu {
                Button(slot.isMuted ? "取消静音" : "静音") {
                    slot.applyMute(!slot.isMuted)
                }
                .disabled(!slot.session.isConnected)
            }
            .accessibilityElement(children: .combine)
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

        @ViewBuilder
        private var trailing: some View {
            if isConnecting {
                ProgressView().controlSize(.mini)
            } else if slot.isMuted {
                // 斜杠图标不是纯色圆点：一个红点的全部信息都在「红」上，
                // 色觉障碍用户看到的是个灰点。形状自己会说话。
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if let sec = runningSeconds {
                Text(verbatim: clock(sec))
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
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
