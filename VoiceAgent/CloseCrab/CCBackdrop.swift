import SwiftUI

/// 背景层：一张图 ＋ 压暗 ＋ 噪点。**Liquid Glass 的折射源。**
///
/// ⚠️ 极光那层 2026-09-22 删了（省电，见 `decorated` 里的墓碑注释）。
/// 下面那段讲「为什么极光不够」的文字留着 —— 它解释了为什么这层要放真图。
///
/// ## 为什么要真图，极光不够
///
/// 那层极光（三团模糊色块）解决的是「背后不能是纯黑」，做到了 ——
/// **但它 2026-09-22 因为省电删掉了**，那份职责交给了静态的 `ambient`。
/// 但它有个硬上限：**三团高斯模糊只有低频信息**。玻璃折射的时候，折出来的
/// 还是一片均匀的颜色 —— 亮了一点、有色相了，可是没有「东西」。
///
/// 真实照片里有云的边缘、星点、网格线、地平线那条亮边 —— 这些中高频细节
/// 被玻璃扭曲之后才会出现那种「隔着一块真玻璃在看」的感觉。这是 Liquid Glass
/// 在系统 app 里好看、在第三方 app 里常常像塑料的主要原因：
/// **系统 app 背后是壁纸和真实内容，第三方 app 背后常常是一块纯色。**
///
/// 所以这一层是图在下、极光在上：
///
/// - **图**是静止的、有细节的，提供折射的纹理
/// - **极光**带着当前 bot 的身份色，是会变的那一层，切 bot 时整片环境光跟着转
/// - **噪点**打散大面积渐变在 8bit 屏上的色带
///
/// ## 图会自己换
///
/// `.auto` 下按时钟走四段天色（黎明/白天/黄昏/夜里）。判断规则在 `CCSky`，
/// 那个文件只依赖 Foundation，Linux 上能真编真跑，所以边界差一错是能被测出来的。
///
/// **不轮询。** `CCSky.secondsUntilNextPhase` 直接算出「还要多久」，
/// 睡那么久再醒一次。定时器每分钟醒一次去比对相位，一天白醒 1436 次，
/// 而它等的事一天只发生 4 次。
struct CCBackdrop: View {
    /// 当前 bot 的主题色。**是可选的** —— 一个房间都没连上时没有当前 bot。
    ///
    /// ⚠️ 用它之前必须解包。`Optional<Color>` 自己 **conform `View`**，
    /// 所以 `tint.opacity(0.3)` 编得过 —— 但命中的是 `View.opacity`，
    /// 返回 `some View` 而不是 `Color`。报错会是莫名其妙的
    /// 「some View 不能转成 Color」，而不是「没有这个方法」。
    /// （2026-09-22 新写 `ambient` 时就栽在这儿。）
    var tint: Color?

    private var config: CloseCrabConfig { .shared }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    /// 当前该显示哪张图。`nil` ＝ 不要图，退回纯极光。
    ///
    /// 存成 `@State` 而不是每次 body 现算：现算的话它依赖 `Date()`，
    /// 而 SwiftUI 不知道时间会变，到点不会重绘。
    @State private var asset: String?

    var body: some View {
        #if os(macOS)
            // ⭐ **Mac 上不铺图、不画极光，只有系统窗口底色。**
            //
            //    Chris 2026-09-21 对着飞书 Mac 版：「它也没有那个 Liquid Glass，
            //    所以你并不需要一个图片当背景，就是纯纯色的，
            //    这样才符合其他应用的设计范式。」
            //
            //    背景图在 iOS 上**不是装饰，是承重的** —— 玻璃要有东西可折射。
            //    Mac 上我们不用玻璃了，它就只剩装饰，而装饰性的满屏图片
            //    恰恰是 Mac 应用里最扎眼的「这不是原生」信号。
            //    顺带还省掉一张图的解码和常驻内存。
            CCMacSurface.window
                .ignoresSafeArea()
        #else
            decorated
        #endif
    }

    /// iOS / visionOS 那一套：背景图 ＋ 压暗 ＋ 极光。
    @ViewBuilder
    private var decorated: some View {
        ZStack {
            // 垫底。图还没解码出来的那一两帧不能是白的 —— 白闪一下比慢一点难看得多。
            Color.bg1

            if let asset {
                image(asset)
                    // `.id` 换了才会走 transition，否则 SwiftUI 认为是同一个 view
                    // 换了内容，会直接硬切。
                    .id(asset)
                    .transition(.opacity)

                scrim
            }

            // ⛔ 这里**曾经**是 `CCAuroraBackground` —— 三团 `blur(radius: 110)`
            //    的全屏椭圆，`onAppear` 起一个 `repeatForever` 动画，**永不停**。
            //
            //    Chris 2026-09-22 00:51：「极光它压根就没用，就不用在后面刷了，
            //    彻底不要了。」
            //
            //    ⚠️ 他之所以说「没用」，是因为**他看到的确实是静止的** ——
            //    有背景图时极光被压到 0.42 强度、藏在图后面几乎看不出来。
            //    但它一直在动、一直在付全价：全屏高斯模糊是 GPU 上的离屏渲染，
            //    锁屏之后照样在烧。
            //
            //    ⇒ **「看不出来的动画」和「不动的画面」渲染成本完全不同。**
            //      一个视觉上无贡献的图层，成本可以是最高的那个。
            //
            //    没有图时的那点环境色改由静态渐变承担（`ambient`）——
            //    它解决的是「背后不能是纯黑」，而那件事**不需要动**。
            if asset == nil {
                ambient
            }
        }
        .ignoresSafeArea()
        // 背景对读屏软件没有任何信息，别让它念一串「图片」。
        .accessibilityHidden(true)
        // scenePhase 进来是故意的：锁屏放了两小时再解锁，得立刻校一次时间。
        // 睡眠那条路自己也会校（醒来读的是当前时间），但会晚一会儿。
        .task(id: "\(config.backdrop.rawValue)|\(scenePhase)") { await follow() }
    }

    // MARK: - 图

    private func image(_ name: String) -> some View {
        // GeometryReader + 显式 frame + clipped：`scaledToFill` 单独用会让图
        // 溢出布局、把父容器撑大。这是 SwiftUI 里最常见的「背景图把界面挤歪」。
        GeometryReader { proxy in
            Image(name)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                // 对比小米之家那套之后加的。我们的问题不是「浅」，是**没颜色** ——
                // 云图本来是蓝天白云，盖上白雾之后渲染出来一片灰白。
                // 降白雾只能少洗一点，洗掉的色相补不回来，得在这一层主动加回去。
                // saturation 先于 scrim 生效（修饰器自下而上作用于这个 Image），
                // 所以这里加的饱和度是"原图的"，不是被雾洗过之后的。
                .saturation(scheme == .dark ? 1.18 : 1.32)
                .contrast(scheme == .dark ? 1.06 : 1.12)
        }
    }

    /// 压在图上的那层雾。
    ///
    /// **两头重中间轻**，不是均匀一层：上边是房间条和方块行，下边是说话条和
    /// 控制栏，这两处压着文字；中间那块是内容窗口，窗口自己有材质，
    /// 图从它周围露出来才有层次。均匀压一层的结果是整张图变成一块脏灰。
    ///
    /// ## 第一版压过头了
    ///
    /// 初版浅色是 0.84 / 0.68 / 0.88 —— 结果是**背景图等于没加**：
    /// 六张图本来就是暗调低对比的，再盖 68% 的白，剩下的信息比原来那三团
    /// 高斯模糊还少。Chris 第一眼的反馈就是「跟之前没啥变化」，他是对的。
    ///
    /// 压这么狠的理由是怕 `.fg0`（近黑）的文字埋进暗图里。**但那是用错了工具**：
    /// 文字的可读性该由文字底下那块材质负责（窗口、说话条、控制栏都有），
    /// 不该让整块背景替它买单。所以这一版把雾调轻，同时把内容窗口从
    /// 不透明白色换成系统材质（见 `CCShell.cardFill`，现行是 `.thickMaterial`）。
    ///
    /// ## 浅色模式天生就淡，这是物理不是 bug
    ///
    /// 六张图都是暗调的，浅色模式下要让近黑的文字活下去就必须提亮，
    /// 提亮就会吃掉对比。**要看这套东西的完整效果，得开深色模式。**
    /// 这一点在设置页的说明里也写了，免得又被当成「设了没反应」。
    /// 没有背景图时垫的那层环境色。**静态渐变，画一次就完了。**
    ///
    /// 它接替的是极光「背后不能是纯黑」那份职责 —— 而那份职责本来就不需要动画。
    /// 保留身份色是因为切 bot 时整片环境色跟着转，那个信号有用且零成本。
    private var ambient: some View {
        // ⚠️ **必须先解包。** `tint` 是 `Color?`，而 `Optional<Color>` 本身
        //    conform `View` —— 直接 `tint.opacity(...)` 会命中 `View.opacity`
        //    返回 `some View`，编译器报的是「some View 不能转成 Color」。
        //    一个房间都没连上时退成中性灰，不假装有身份色。
        let hue = tint ?? .fg3
        return LinearGradient(
            colors: [hue.opacity(0.28), .bg1, hue.opacity(0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var scrim: some View {
        LinearGradient(
            // 第四版。第一版 0.84/0.68/0.88 等于没加图，第二版 0.66/0.38/0.70 还是闷，
            // 第三版（深 0.34/0.06/0.46，浅 0.56/0.24/0.62）反过来又太淡：
            // 深色模式背景发灰立不住，浅色模式那层白把图刷没了。
            //
            // 这一版两个方向都往「更深」走，但手法不同：
            //   深色 —— 加黑，让背景沉下去，玻璃才浮得起来
            //   浅色 —— **减白**。浅色发淡不是因为黑得不够，是白刷得太多
            // 面板那边同步提到 `.regularMaterial` 0.88，文字的衬底由它负责，
            // 所以这层不用再替可读性买单。
            // 浅色这一档**不用纯白**。纯白是去饱和剂：刷多少就吃掉多少色相，
            // 而我们的图恰恰靠蓝色撑住"天"的观感（小米那张之所以好看，
            // 核心就是天是蓝的）。改成带一点蓝的冷调，压亮度但不杀颜色。
            colors: scheme == .dark
                ? [.black.opacity(0.46), .black.opacity(0.18), .black.opacity(0.58)]
                : [Color(red: 0.78, green: 0.85, blue: 0.95).opacity(0.30),
                   Color(red: 0.86, green: 0.91, blue: 0.98).opacity(0.08),
                   Color(red: 0.74, green: 0.82, blue: 0.94).opacity(0.38)],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    // MARK: - 跟着时间走

    /// 算一次现在该显示哪张，然后睡到下一个天色边界再算一次。
    ///
    /// 手动锁定（非 `.auto`）时算完就退出循环 —— 锁死的图不会自己变，
    /// 留一个永远在睡的任务没有意义。
    private func follow() async {
        while !Task.isCancelled {
            let now = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
            let hour = now.hour ?? 0
            let minute = now.minute ?? 0
            let next = CCSky.asset(for: config.backdrop, hour: hour, minute: minute)

            if next != asset {
                withAnimation(.easeInOut(duration: 0.9)) { asset = next }
            }

            guard config.backdrop == .auto else { return }

            let wait = CCSky.secondsUntilNextPhase(hour: hour, minute: minute, second: now.second ?? 0)
            // `secondsUntilNextPhase` 保证返回正数（`CCLookTests` 里全天 4320 个
            // 时刻都验过）。真返回 0 的话这里会变成忙等把电烧光，所以再兜一道 ——
            // 断言在 release 里是不存在的，这个 max 才是真正的保险。
            try? await Task.sleep(for: .seconds(max(wait, 1)))
        }
    }
}

// MARK: - 深浅色

extension CCAppearance {
    /// 交给 `.preferredColorScheme` 的值。`nil` ＝ 跟随系统。
    ///
    /// 枚举本身放在 `CCLook.swift`（只依赖 Foundation，Linux 上能测），
    /// 这条到 SwiftUI 的映射放在这儿 —— 边界就在「要不要 import SwiftUI」。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
