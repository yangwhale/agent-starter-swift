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
/// 界面各处从环境里读 `Session` / `LocalMedia` / `CCMicPolicy` / `CCRoomSlot`，
/// 改多房间时**一处都没动**。这里保持那个契约：
///
/// - chrome（控制栏、说话条）拿的是**当前槽位**的那一份
/// - 每一页在自己子树里再注入**自己槽位**的那一份，就近覆盖外层
///
/// **两种注入方式并存，不是没统一**：`Session` / `LocalMedia` 是 LiveKit SDK
/// 的类型，仍然是 `ObservableObject`，只能走 `.environmentObject`；我们自己的
/// 类型全部是 `@Observable`，走 `.environment`。SDK 换代之前这条线就在这儿。
///
/// 所以页面里的 `AgentView` 读到的永远是本页那个房间，哪怕它此刻不是当前页。
struct CCRootView: View {
    let rooms: CCRooms

    #if os(macOS)
        /// Mac 的按住说话。**单例** —— 全局事件监听只该有一个，
        /// 每次视图重建都新建一个的话会挂出一堆重复监听器。
        private var hotkey: CCMacHotkey { .shared }
    #endif

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
        .environment(rooms)
        .environment(\.namespace, namespace)
        // 背景垫在最底下。它是 Liquid Glass 的折射源 —— 没有它,
        // 上面所有玻璃都只是半透明灰块。详见 CCBackdrop。
        .background {
            CCBackdrop(tint: rooms.active.map { CCIdentityColor.color(for: $0.name) })
        }
        #if os(macOS)
            .onAppear {
                // 单例先于房间层存在，所以是启动时把房间接上，不是构造时
                hotkey.bind(
                    micPolicy: { [weak rooms] in rooms?.active?.micPolicy },
                    isMicOn: { [weak rooms] in
                        rooms?.active?.localMedia.isMicrophoneEnabled ?? false
                    }
                )
                hotkey.setKey(CloseCrabConfig.shared.pushToTalkKey)
                hotkey.start()
            }
            // 设置页里一拨就生效，不用重启
            .onChange(of: CloseCrabConfig.shared.pushToTalkKey) { _, new in
                hotkey.setKey(new)
            }
            // 说完了发个通知 —— Mac 上你问完就切去干别的了，
            // 答案说完散在空气里没人知道。只在不在前台时发，见 CCMacNotify。
            .onChange(of: rooms.active?.isSpeaking ?? false) { was, now in
                if was, !now, let name = rooms.active?.name {
                    CCMacNotify.spoke(room: name)
                }
            }
            // 窗口聚焦时的空格路径。全局热键要辅助功能授权，**这条不需要** ——
            // 没授权时它是唯一能用的按住说话方式，所以两条都得有。
            .onKeyPress(keys: [.space], phases: [.down, .up]) { press in
                hotkey.space(down: press.phase == .down, isTextInputActive: false)
                return .handled
            }
        #endif
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
    let rooms: CCRooms
    let active: CCRoomSlot
    /// 要订阅，不能直接读 `.shared` —— 直接读拿得到值，但**开关拨了界面不会重绘**。
    private var config: CloseCrabConfig { .shared }

    /// 聊天（字幕）开关。**提到 chrome 这一层 = 跨房间共享**：
    /// 开着字幕滑到隔壁，字幕还开着。字幕是「我想看文字」这个偏好，
    /// 不是某个房间的属性，跟着房间走反而每次都要重开。
    @State private var chat = false
    @State private var roomsPresented = false
    @FocusState private var keyboardFocus: Bool

    #if os(macOS)
        /// 工具栏那两颗要开独立场景。**名字不跟 SwiftUI 的环境键同名** ——
        /// 同名读起来像是覆盖了它。
        @Environment(\.openWindow) private var openDiagWindow
        @Environment(\.openSettings) private var openSettingsWindow
    #endif

    /// 方块本体的边长。**必须和 `CCRoomTile` 里那个 `side` 同源同缩放** ——
    /// 汉堡要对齐的是**方块本体的中线**，而方块会跟着系统字号长。
    /// 写死 54 的话，用户把字号调大，汉堡就会越偏越低。
    @ScaledMetric(relativeTo: .caption) private var tileSide: CGFloat = CC.Size.tile
    /// 方块行自己的上内边距，抄自 `CCRoomTileRow`。汉堡要跟它对齐。
    private static let tileRowInsetTop: CGFloat = 2 * .grid

    var body: some View {
        ZStack {
            if active.isConnected {
                connected()
            } else {
                StartView()
            }

            errors()
        }
        // chrome 读当前槽位。每一页会在自己子树里覆盖成本页的。
        // `session` / `localMedia` 是 LiveKit SDK 的类型，还是 ObservableObject，
        // 只能走 `.environmentObject`。我们自己的一律走 `.environment`。
        .environmentObject(active.session)
        .environmentObject(active.localMedia)
        .environment(active.micPolicy)
        .environment(active)
        .ccAnimation(.default, value: active.isConnected)
        .ccAnimation(.default, value: chat)
        // 预热 Taptic Engine。不热身的话第一下手势会明显迟半拍 ——
        // 而第一下恰恰是「这 app 有没有震动」的全部印象。
        //
        // 用 `onAppear` 不用 `task`：要叫的是个**同步**的 MainActor 方法。
        // `task` 的闭包是 `@Sendable` 的，在里面直接同步调 MainActor 方法
        // 在 Swift 6 下未必过得了；`onAppear` 收的是普通同步闭包，
        // 在这个工程（默认 MainActor 隔离）下必然继承主 actor。
        // ⛔ **这一条必须挂在 body 上，不能挂在那颗汉堡上。**
        //
        //    它原来跟着 `menuButton()` 走 —— 而 `menuButton()` 只在
        //    `touchLayout()` 里。Mac 走的是 `macLayout()`，于是整个 sheet
        //    修饰符**根本不在视图树上**：⌘K 把 `roomsPresented` 置了真，
        //    但没有任何人在听它，表现是「按了没反应」。
        //    Chris 2026-09-21 报的「房间列表点不开」就是这个。
        //
        //    教训：**把「弹出什么」挂在「谁触发它」身上，是个耦合陷阱** ——
        //    触发者换了平台，弹出能力就一起没了，而且编译期完全无声。
        .sheet(isPresented: $roomsPresented) {
            CCRoomListView()
        }
        .onAppear { CCHaptics.warmUp() }
        #if os(iOS)
        .sensoryFeedback(.impact, trigger: active.isConnected)
        #endif
        #if os(macOS)
        // 把「打开房间抽屉」这个开关交给菜单（⌘K）。
        // **用 focusedSceneValue 而不是单例**：值跟着当前获得焦点的窗口走，
        // 将来一个房间一个窗口时才不会作用错对象。理由写在 CCMacCommands 里。
        .focusedSceneValue(\.ccRoomDrawer, $roomsPresented)
        .focusedSceneValue(\.ccChatVisible, $chat)
        #endif
    }

    // MARK: - 连上之后

    /// 连上之后的主体。**两个平台是两种布局，不是一种布局的两个尺寸。**
    ///
    /// 手机竖着拿，横向是唯一的富余方向 —— 所以房间排成一排、靠滑动翻页，
    /// 内容一列到底。Mac 正好反过来：竖向有的是空间，横向是拿来放内容的。
    /// 所以 Mac 走侧栏 ＋ 内容两栏，方块行和那截颈部在 Mac 上整个不出现。
    ///
    /// ⚠️ 拆成两个函数而不是在里面插 `#if`：`#if` **劈不开 `VStack {` 那对
    /// 花括号**（那不是合法 Swift）。这条坑 `VoiceAgentApp` 里也记过一次。
    @ViewBuilder
    private func connected() -> some View {
        #if os(macOS)
            macLayout()
        #else
            touchLayout()
        #endif
    }

    #if os(macOS)
        /// Mac：左边房间侧栏，右边这个房间的全部。
        @ViewBuilder
        private func macLayout() -> some View {
            NavigationSplitView {
                CCMacRoomSidebar(rooms: rooms, roomsPresented: $roomsPresented)
            } detail: {
                pager()
                    // 说话条 ＋ 控制栏仍然在底部。
                    //
                    // **没有跟着挪进工具栏**：说话条是这个 app 里按得最频繁的
                    // 东西，而且全局热键（右 Option）读的就是它那套状态 ——
                    // 把它挪到窗口顶上，手和眼睛都要多跑一趟。
                    // 静音 / 字幕 / 挂断那几个是候选，等侧栏落地之后再说。
                    .safeAreaInset(edge: .bottom) {
                        if !keyboardFocus { bottomBar() }
                    }
                    // ⭐ **齿轮在右上角工具栏 —— 这是 Mac 的位置。**
                    //
                    //    Chris 2026-09-21 指着飞书 Mac 版：setting 按钮的摆放
                    //    也要学。看那张图，右上角一排图标按钮，齿轮在最右 ——
                    //    几乎每个 Mac 应用都是这个位置，它已经是肌肉记忆。
                    //
                    //    这三颗跟菜单里那三条是**同一批动作**，不是新功能。
                    //    菜单负责「不用鼠标怎么做 ＋ 让人知道有」，
                    //    工具栏负责「手在鼠标上时一下点到」。两者都要有。
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button {
                                roomsPresented = true
                            } label: {
                                Image(systemName: "person.2")
                            }
                            .help(Text(verbatim: "管理房间（⌘K）"))

                            Button {
                                openDiagWindow(id: CCWindowID.diagnostics)
                            } label: {
                                Image(systemName: "waveform.badge.magnifyingglass")
                            }
                            .help(Text(verbatim: "诊断（⌘⌥D）"))

                            Button {
                                openSettingsWindow()
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .help(Text(verbatim: "设置（⌘,）"))
                        }
                    }
            }
        }
    #endif

    @ViewBuilder
    private func touchLayout() -> some View {
        VStack(spacing: 0) {
            // 方块行 + 颈部。绑在一起是因为颈部要读方块的位置：
            // preference 只能从子树往上冒，overlay 必须挂在**包住方块行**的那一层。
            VStack(spacing: 0) {
                // ⭐ 汉堡和方块**共享第一行**（Chris 2026-09-20）。
                //    原来汉堡自己占一整行摆在左上角，方块行在它下面 ——
                //    等于为一颗图标付掉一整行高度，而那一行剩下全是空白。
                //
                //    汉堡放右边不是随意选的：左边要给方块行让位，而方块行是
                //    **可以横向滚的**，右边这颗必须钉死不动，否则房间一多
                //    它就跟着滚出屏幕了。滚动区域是 HStack 里的弹性一方，
                //    这颗按钮是固定一方，宽度自动让出来。
                //    ⚠️ **对齐的是方块本体的中线，不是整行的中线。**
                //    方块底下还挂着一行名字，按整行居中的话汉堡会低约 13pt ——
                //    Chris 2026-09-20 第一眼就看出来了：「它有点低了，应该往上点」。
                //    做法：整个 HStack 顶对齐，汉堡自己占一格**和方块等高**的区域，
                //    在那一格里居中 → 圆心正好落在方块中线上，而且跟着字号一起长。
                HStack(alignment: .top, spacing: 0) {
                    CCRoomTileRow()
                    menuButton()
                        .frame(height: tileSide)
                        .padding(.top, Self.tileRowInsetTop)
                }
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

    /// 右上角那颗汉堡 —— 房间列表的入口。
    ///
    /// ## 为什么只有三条杠，名字去掉了
    ///
    /// Chris 2026-09-20：「那个字不要了，就只要三个横杠，那就省地方。」
    ///
    /// 名字**没有丢**：它就写在下面每个方块底下，当前那个还额外有玻璃材质
    /// 和颈部指着它。房间条上再写一遍是同一件事说两遍，而它占掉的是
    /// 这一行里最贵的横向空间 —— 方块行要往右滚的那部分。
    ///
    /// ⚠️ **但读屏用户会丢。** 他们看不到「哪个方块是选中的」那套视觉语言，
    /// 原来那行文字是他们唯一知道当前房间的地方。所以名字挪进
    /// `accessibilityValue` —— 屏幕上省掉，读屏里留着。
    /// （去掉可见文字＝同时去掉读屏内容，这一步很容易漏。）
    private func menuButton() -> some View {
        Button {
            roomsPresented = true
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.fg0)
                // 11 × 4 = 44pt，正好是 Apple 给的最小点击目标。
                // 图标本身只有 17pt，剩下的是「摸得着」的余量。
                .frame(width: 11 * .grid, height: 11 * .grid)
                // 跟控制栏那排按钮同一种材质。
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("房间列表"))
        .accessibilityValue(Text(rooms.activeName))
        .padding(.trailing, 4 * .grid)
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
                    .strokeBorder(Self.cardStroke, lineWidth: Self.cardLine)
            )
            // iPad 上限宽居中，iPhone 上比屏还宽所以是空操作。见 CC.Size.contentMax。
            .frame(maxWidth: CC.Size.contentMax)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, CC.Space.screen)
            // ⚠️ **这里一点都不留。** 窗口是 VStack 里唯一会伸缩的一块，
            //    所以这一格每减一点都直接变成窗口变高。
            //    Chris 2026-09-20：「照比下面那个按住说话中间有个缝……
            //    把这两个缝给我弄没有。我给你省出来的地方不是让你留缝的，
            //    是让你把中间的框变大的。」
            //
            //    说话条本身是一块玻璃、有自己的形状，窗口是实心圆角卡片 ——
            //    两者直接相邻不会糊在一起。真要是看着贴太紧，
            //    加回 `CC.Space.hairline`（2pt）就够，别加回 10。
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
            .environment(slot.micPolicy)
            // ⭐ 给这一页的几何动画 id 分区。**不分区的话相邻页会抢同一个 id** ——
            //    理由写在 `EnvironmentValues.geoScope` 上，那条是承重的。
            .environment(\.geoScope, slot.name)
            // ⭐ 把**槽位本身**注入这一页。界面读它的 @Observable 镜像属性，
            //    不再 `@EnvironmentObject` 订阅 LiveKit 那个 Session ——
            //    后者是老式对象，**读它任何一个属性就等于订阅它全部变化**。
            .environment(slot)
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
        .frame(maxWidth: CC.Size.contentMax)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CC.Space.screen)
        .padding(.bottom, CC.Space.tight)
    }

    // MARK: -

    /// 错误条。
    ///
    /// ## 两个坑，14:22 那张截图上同时中了
    ///
    /// **一、它盖在柱状图正中间。** 原来整组挂在 `ZStack` 里不给对齐，
    /// 默认居中 —— 而屏幕正中间正好是可视化那块。一条「连接超时」把
    /// 唯一在动的东西整个遮住，人会以为界面死了。挪到顶上去。
    ///
    /// **二、连接恢复了它还赖着不走。** `session.error` 是粘性的，只有点叉才消。
    /// 于是一次瞬时的连接超时（同时连四个房间，其中一个慢了）会在屏幕上
    /// 留一条红色的「Connection failed」，而那个房间其实早就连上了 ——
    /// 截图里 jarvis 的方块是亮的、状态写着「在听,说吧」，红条却还在。
    ///
    /// 修法是：**连上了就自动把连接类的错误清掉**。判据用「现在连着」
    /// 而不是「过了多久」—— 后者只是把问题推迟，前者是问题本身没了。
    ///
    /// 媒体错误（麦克风拿不到）不自动清：那个不会自己好。
    @ViewBuilder
    private func errors() -> some View {
        #if !os(visionOS)
            VStack(spacing: CC.Space.tight) {
                if let error = active.connectionError, !active.isConnected {
                    ErrorView(error: error, room: active.name) { active.session.dismissError() }
                }

                if let agentError = active.agentError, !active.isConnected {
                    ErrorView(error: agentError, room: active.name) { Task { await active.session.end() }}
                }

                if let mediaError = active.localMedia.error {
                    ErrorView(error: mediaError) { active.localMedia.dismissError() }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // 连上那一刻红条要滑走，不要「啪」地消失 —— 突然消失会让人
            // 怀疑自己看错了，滑走才读得出「刚才那个问题解决了」。
            .ccAnimation(CC.Motion.snap, value: active.isConnected)
        #endif
    }

    // MARK: - 样式

    /// 窗口和颈部共用同一套描边/填充，接缝处才不会露馅。
    ///
    /// ## 填充从「不透明白」换成了材质
    ///
    /// 原来是 `Color.bg2` —— 浅色模式下那是**纯白、不透明**。而这块窗口占了
    /// 屏幕六成以上，于是加了背景图之后整屏只剩四边一圈能看见图，
    /// 中间最大的一块还是一张白纸。Chris 装上第一版的反应是「跟之前没啥变化」，
    /// 根因一半在这儿（另一半是那层雾压太狠，见 `CCBackdrop.scrim`）。
    ///
    /// **Liquid Glass 的价值在于背后有东西可折射 —— 前提是它自己得是透的。**
    /// 一个不透明的大白块盖在背景图上，等于把折射源挡掉，剩下的玻璃
    /// （说话条、控制栏、方块）只能折射到边角那一点点图。
    ///
    /// 换成系统材质：它自带模糊和对环境色的采样，底下的图能透出来，
    /// 同时文字仍然坐在一层材质上，可读性不靠背景买单。
    ///
    /// ## 为什么颈部也得跟着换，而且必须是同一个
    ///
    /// 颈部是把方块和窗口缝成一体的那截带子。两边材质只要有一点差别，
    /// 接缝处就会出现一道边 —— 而那道边正好在最显眼的位置上。
    /// 所以 `CCTileNeckView.fill` 的类型从 `Color` 放宽成 `AnyShapeStyle`，
    /// 就是为了让它能收下同一个材质。
    #if os(macOS)
        /// Mac 上用系统分隔线色。**跟旁边系统控件颜色差一点点，
        /// 恰恰是最容易被看出来不原生的地方** —— 所以不自己调十六进制。
        private static let cardStroke = CCMacSurface.separator
        private static let cardLine: CGFloat = 1
    #else
        private static let cardStroke = Color.separator1
        private static let cardLine: CGFloat = 1.5
    #endif

    /// 窗口/颈部的填充。**四版下来只调这一个值，历史全在这儿。**
    ///
    /// | 版本 | 值 | 为什么换掉 |
    /// |---|---|---|
    /// | ① | `Color.bg2`（不透明白） | 占屏六成的大白块把折射源挡死，等于没加背景图 |
    /// | ② | `.ultraThinMaterial` × 0.62 | 反过来透过头：面板几乎不存在，文字直接压在云上 |
    /// | ③ | `.regularMaterial` × 0.88 | 还是偏透，中间态 |
    /// | ④ | **`.thickMaterial`，不乘透明度** | 现行 |
    ///
    /// 第四版是对比小米之家那套定的：**他们的卡片基本是实心的** ——
    /// 背景透不过来，卡片是「贴在」背景上的实体，不是「融进」背景。
    ///
    /// `.thickMaterial` 仍然会模糊、会采样环境色（Liquid Glass 的折射还在），
    /// 但面板本身是一块看得见、立得住的东西。
    ///
    /// ⛔ **不要再往上乘透明度了。** ②③ 两版都试过这条路，
    /// 结论是玻璃的实体感靠材质厚度，不靠把它调淡 ——
    /// 乘出来的只是「一层没擦干净的膜」，不是玻璃。
    #if os(macOS)
        /// ⚠️ **Mac 上不能用材质。** `.thickMaterial` 是半透明的 ——
        /// 它假设背后有东西（背景图）值得透出来。去掉背景图之后，
        /// 半透明只会让这块面板跟窗口底色糊在一起，边界消失。
        /// 换成实心的系统面板色，面板边界靠那 1px 线说清楚。
        private static let cardFill = AnyShapeStyle(CCMacSurface.panel)
    #else
        private static let cardFill = AnyShapeStyle(.thickMaterial)
    #endif
}
