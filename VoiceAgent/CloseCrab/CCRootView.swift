import LiveKit
import SwiftUI

/// 多房间和既有界面之间的**唯一接缝**，同时也是整屏的布局中枢。
///
/// ## 分层
///
/// ```
/// ┌─────────────────────────┐
/// │ 汉堡 + 房间名            │  常驻
/// │ ■ ■ ■  方块行            │  常驻
/// │      ╲╱  颈部            │  常驻，x 跟着当前方块走
/// │ ┌───────────────────┐   │
/// │ │   内容窗口         │   │  ← 只有这里分页，左右滑切 bot
/// │ └───────────────────┘   │
/// │ [   按住说话   ]         │  常驻
/// │ [ 控制栏 ]               │  常驻
/// └─────────────────────────┘
/// ```
///
/// **为什么 chrome 必须常驻**：原来方块行长在 `AppView` 里，而 `AppView` 挂着
/// `.id(slot.name)`，切房间时整棵子树销毁重建 —— 方块行自己都会闪一下，
/// 更不可能有「整体滑过去」的动画。要做滑动切换，先得把不该重建的东西拿出来。
///
/// ## 环境对象怎么给
///
/// 全 app 有 19 处从环境里读 `Session` / `LocalMedia` / `AudioOptions` /
/// `CCMicPolicy`，改多房间时**一处都没动**。这里保持那个契约：
///
/// - chrome（控制栏、说话条）拿的是**当前槽位**的那一份
/// - 每一页在自己子树里再注入**自己槽位**的那一份，就近覆盖外层
///
/// 所以页面里的 `AgentView` 读到的永远是本页那个房间，哪怕它此刻不是当前页。
struct CCRootView: View {
    @ObservedObject var rooms: CCRooms

    /// 放在最外层而不是每页一个：`matchedGeometryEffect` 的两端如果落在
    /// 不同 namespace 里会直接崩（`namespace!` 强解包）。
    @Namespace private var namespace

    var body: some View {
        Group {
            if let active = rooms.active {
                CCShell(rooms: rooms, active: active)
            } else {
                empty()
            }
        }
        .environmentObject(rooms)
        .environment(\.namespace, namespace)
        // 极光垫在最底下。它是 Liquid Glass 的折射源 —— 没有它,
        // 上面所有玻璃都只是半透明灰块。详见 CCAuroraBackground。
        .background {
            CCAuroraBackground(tint: rooms.active.map { CCIdentityColor.color(for: $0.name) })
        }
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

// MARK: -

/// 真正的布局。
///
/// 单独拆出来只为一件事：**用 `@ObservedObject` 订阅当前槽位**。
/// `CCRooms` 只在槽位增删、切换时发通知，当前这条连接连上没有是槽位自己的事 ——
/// 写在 `CCRootView` 里的话，连上之后启动页不会自己退下去。
private struct CCShell: View {
    @ObservedObject var rooms: CCRooms
    @ObservedObject var active: CCRoomSlot
    /// 要订阅，不能直接读 `.shared` —— 直接读拿得到值，但**开关拨了界面不会重绘**。
    @ObservedObject private var config = CloseCrabConfig.shared

    /// 聊天（字幕）开关。**提到 chrome 这一层 = 跨房间共享**：
    /// 开着字幕滑到隔壁，字幕还开着。字幕是「我想看文字」这个偏好，
    /// 不是某个房间的属性，跟着房间走反而每次都要重开。
    @State private var chat = false
    @State private var roomsPresented = false
    @FocusState private var keyboardFocus: Bool

    var body: some View {
        ZStack {
            if active.session.isConnected {
                connected()
            } else {
                StartView()
            }

            errors()
        }
        // chrome 读当前槽位。每一页会在自己子树里覆盖成本页的。
        .environmentObject(active.session)
        .environmentObject(active.localMedia)
        .environmentObject(active.audioOptions)
        .environmentObject(active.micPolicy)
        .animation(.default, value: active.session.isConnected)
        .animation(.default, value: chat)
        #if os(iOS)
        .sensoryFeedback(.impact, trigger: active.session.isConnected)
        #endif
    }

    // MARK: - 连上之后

    @ViewBuilder
    private func connected() -> some View {
        VStack(spacing: 0) {
            roomBar()

            // 方块行 + 颈部。绑在一起是因为颈部要读方块的位置：
            // preference 只能从子树往上冒，overlay 必须挂在**包住方块行**的那一层。
            VStack(spacing: 0) {
                CCRoomTileRow()
                Color.clear.frame(height: CCTileConnector.height)
            }
            .overlayPreferenceValue(CCTileAnchorKey.self) { anchors in
                CCTileNeckView(
                    anchors: anchors,
                    activeName: rooms.activeName,
                    stroke: Self.cardStroke,
                    fill: Self.cardFill
                )
                .frame(height: CCTileConnector.height)
                .frame(maxHeight: .infinity, alignment: .bottom)
                // 颈部是画上去的装饰，不能挡住方块的点击。
                .allowsHitTesting(false)
            }

            pager()
        }
        #if os(visionOS)
        // visionOS 的控制栏是挂在窗口外面的 ornament，不占布局空间。
        .ornament(attachmentAnchor: .scene(.bottom)) {
            bottomBar()
                .glassBackgroundEffect()
        }
        #else
        .safeAreaInset(edge: .bottom) {
                if !keyboardFocus {
                    bottomBar()
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
        #endif
    }

    /// 左上角那颗汉堡 —— 房间列表的入口，也顺便告诉你现在在跟谁说话。
    private func roomBar() -> some View {
        HStack {
            Button {
                roomsPresented = true
            } label: {
                HStack(spacing: 2 * .grid) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 15, weight: .medium))
                    Text(verbatim: rooms.activeName)
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(.fg0)
                .padding(.horizontal, 4 * .grid)
                .padding(.vertical, 2 * .grid)
                .background(Capsule().fill(.bg2))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 4 * .grid)
        .padding(.top, 2 * .grid)
        .sheet(isPresented: $roomsPresented) {
            CCRoomListView()
        }
    }

    /// 内容窗口。**只有这一块分页**。
    ///
    /// 窗口框是静止的，换的是里面的内容 —— 跟浏览器标签页一样：
    /// 标签移过去了，窗口还在原地。整个框跟着一起飞反而会让人以为换了个界面。
    private func pager() -> some View {
        pages()
            .background(
                RoundedRectangle(cornerRadius: CC.Radius.card, style: .continuous)
                    .fill(Self.cardFill)
            )
            .clipShape(RoundedRectangle(cornerRadius: CC.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CC.Radius.card, style: .continuous)
                    .strokeBorder(Self.cardStroke, lineWidth: 1.5)
            )
            .padding(.horizontal, CC.Space.screen)
            .padding(.bottom, CC.Space.snug)
    }

    @ViewBuilder
    private func pages() -> some View {
        #if os(iOS)
            // 页序和方块行一致，走 TabView 的标准分页方向：
            // 手指往左划 = 数组里的下一个 = 右边那个方块。
            //
            // 中间试过倒过来（把内容当一排实体按键、往左划取左边那个），
            // 真机上手后还是标准方向顺手 —— 它和系统相册、日历、
            // 所有分页界面是同一套肌肉记忆，独树一帜的代价比收益大。
            TabView(selection: pageSelection) {
                ForEach(rooms.slots) { slot in
                    page(slot)
                        .tag(slot.name)
                }
            }
            // 不要那排小圆点：方块行已经是更好的索引器，
            // 再来一排点就是同一件事说两遍，还占掉窗口底部一条。
            .tabViewStyle(.page(indexDisplayMode: .never))
        #else
            // macOS / visionOS 没有分页样式，也没有横滑的意义 —— 直接显示当前房间。
            page(active)
        #endif
    }

    private func page(_ slot: CCRoomSlot) -> some View {
        AppView(chat: chat, keyboardFocus: $keyboardFocus)
            .environmentObject(slot.session)
            .environmentObject(slot.localMedia)
            .environmentObject(slot.audioOptions)
            .environmentObject(slot.micPolicy)
    }

    /// 分页选中项。
    ///
    /// **不能直接 `$rooms.activeName`** —— 那样只改了个字符串，
    /// `activate()` 里「把旧房间的麦克风关掉、同步 config.room」全跳过了。
    /// 全进程只有一个采集设备，漏掉关麦就是两个房间同时开着麦。
    private var pageSelection: Binding<String> {
        Binding(
            get: { rooms.activeName },
            set: { rooms.activate($0) }
        )
    }

    /// 说话条 + 控制栏。键盘起来时整块让位。
    private func bottomBar() -> some View {
        // 两条同属一个玻璃容器：靠得近时系统会让两块玻璃的形状互相影响，
        // 出现/消失时也能互相融进融出，而不是各弹各的。
        VStack(spacing: CC.Space.tight) {
            // 读数挂在玻璃容器**外面**：它不是控件，是仪表。
            // 放进容器会被当成一块要参与形变的玻璃，语义不对，
            // 而且它宽度一变就会带着说话条一起形变，很吵。
            if config.netReadout {
                CCNetReadout()
            }

            GlassEffectContainer(spacing: CC.Space.snug) {
                VStack(spacing: CC.Space.snug) {
                    CCTalkBar()
                    ControlBar(chat: $chat)
                }
            }
        }
        .padding(.horizontal, CC.Space.screen)
        .padding(.bottom, CC.Space.tight)
    }

    // MARK: -

    @ViewBuilder
    private func errors() -> some View {
        #if !os(visionOS)
            if let error = active.session.error {
                ErrorView(error: error) { active.session.dismissError() }
            }

            if let agentError = active.session.agent.error {
                ErrorView(error: agentError) { Task { await active.session.end() }}
            }

            if let mediaError = active.localMedia.error {
                ErrorView(error: mediaError) { active.localMedia.dismissError() }
            }
        #endif
    }

    // MARK: - 样式

    /// 窗口和颈部共用同一套描边/填充，接缝处才不会露馅。
    ///
    /// 用调色板里的语义色而不是写死的灰：这两个都带浅色/深色两份，
    /// 跟随系统切换时自己会翻过来。
    private static let cardStroke = Color.separator1
    private static let cardFill = Color.bg2
}
