import SwiftUI

/// 背景层：一张图 ＋ 极光 ＋ 噪点。**Liquid Glass 的折射源。**
///
/// ## 为什么要真图，极光不够
///
/// `CCAuroraBackground` 那三团模糊色块解决的是「背后不能是纯黑」，做到了。
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
    /// 当前 bot 的主题色，透给极光那一层。
    var tint: Color?

    @ObservedObject private var config = CloseCrabConfig.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    /// 当前该显示哪张图。`nil` ＝ 不要图，退回纯极光。
    ///
    /// 存成 `@State` 而不是每次 body 现算：现算的话它依赖 `Date()`，
    /// 而 SwiftUI 不知道时间会变，到点不会重绘。
    @State private var asset: String?

    var body: some View {
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

            // 极光压在图上面。它是**会变**的那一层（跟着 bot 身份色转），
            // 图是固定的那一层。
            //
            // 有图的时候极光要压弱：两层都开满会互相打架，出来一片浑浊的紫。
            // 有图时它的职责退化成「给当前 bot 一点环境色」，不再是主视觉。
            CCAuroraBackground(
                tint: tint,
                showsBase: asset == nil,
                intensity: asset == nil ? 1 : 0.42
            )
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
    /// 不透明白色换成 `.ultraThinMaterial`（见 `CCShell.cardFill`）。
    ///
    /// ## 浅色模式天生就淡，这是物理不是 bug
    ///
    /// 六张图都是暗调的，浅色模式下要让近黑的文字活下去就必须提亮，
    /// 提亮就会吃掉对比。**要看这套东西的完整效果，得开深色模式。**
    /// 这一点在设置页的说明里也写了，免得又被当成「设了没反应」。
    private var scrim: some View {
        LinearGradient(
            // 第三版。第一版 0.84/0.68/0.88 等于没加图，第二版 0.66/0.38/0.70
            // 还是闷。现在窗口自己也透了（`CCShell.cardFill` 乘了 0.62），
            // 文字的衬底有人负责，这一层可以再让一步。
            colors: scheme == .dark
                ? [.black.opacity(0.34), .black.opacity(0.06), .black.opacity(0.46)]
                : [.white.opacity(0.56), .white.opacity(0.24), .white.opacity(0.62)],
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
