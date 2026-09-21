import LiveKitComponents
import SwiftUI

/// The initial view that is shown when the app is not connected to the server.
struct StartView: View {
    @Environment(CCRooms.self) private var rooms
    private var config: CloseCrabConfig { .shared }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var button

    @State private var settingsPresented = false
    @State private var roomsPresented = false

    /// 启动页那一列的最大宽度。**跟登录框、表单一个量级** ——
    /// 这一屏的信息量就是「选谁 ＋ 开始」，给它整屏宽度只会让两个控件
    /// 各自拉成一条，彼此的关系反而看不出来。
    private static let columnMax: CGFloat = 360

    /// 这一屏那几个控件的高度。
    ///
    /// ⚠️ **Mac 不能照抄 56。** 那个数是按「拇指按得准」来的 ——
    /// 手指的接触面积约 44pt，主操作再大一号才好按。
    /// 鼠标是个像素级的指针，**它不需要这个余量**；
    /// Mac 的标准按钮高度在 28–32 一带，摆一个 56pt 高的按钮在旁边，
    /// 它跟系统控件根本不在一个尺度上。
    ///
    /// 这跟「按钮太大」是同一件事的两个面：横向是 columnMax 收的，纵向是这里。
    #if os(macOS)
        private static let controlHeight: CGFloat = 34
    #else
        private static let controlHeight: CGFloat = CC.Size.bar
    #endif

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            mark()
                .padding(.bottom, CC.Space.loose)

            Text(verbatim: "CloseCrab")
                .font(.largeTitle.bold())
                .foregroundStyle(.fg0)

            Text(verbatim: "挑一个助理，按住说话")
                .font(.subheadline)
                .foregroundStyle(.fg3)
                .padding(.top, CC.Space.tight)

            Spacer()

            roomPicker()
                .padding(.bottom, CC.Space.snug)

            connectButton()

            settingsButton()
                .padding(.top, CC.Space.regular)

            Spacer()
        }
        // ⭐ **整列限宽居中 —— 这是这一屏最要命的一条。**
        //
        //    Chris 2026-09-21：「这个开屏巨大的紫色按钮，我非常不满意，
        //    跟现代化的应用格格不入。」
        //
        //    他指的是颜色，但**面积才是主因**。同一个紫色，
        //    做成 320pt 宽的按钮是「主操作」，铺满 1500pt 就是「一堵墙」——
        //    强调色的用量规则是：**小到你会想去点它，而不是大到你无法忽视它。**
        //
        //    满宽 CTA 不是没有出处：iOS 底部那种「继续 / 购买」就是满宽的。
        //    但那是**钉在底部安全区上方**的固定位置，靠屏幕边缘框住它。
        //    浮在屏幕正中间的满宽色块没有任何东西框着，
        //    读起来就是一条网页横幅。
        //
        //    360 是按「一行按钮字数」取的，跟登录框、表单一个量级。
        .frame(maxWidth: Self.columnMax)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, CC.Space.screen)
        #if os(visionOS)
        .glassBackgroundEffect()
        .frame(maxWidth: 175 * .grid)
        #endif
    }

    /// 那五根竖条。**不再是干巴巴五个矩形** —— 包进一块圆形玻璃里，
    /// 它就从「一张贴图」变成了这一屏的主体。
    private func mark() -> some View {
        HStack(alignment: .center, spacing: 5) {
            let heights: [CGFloat] = [12, 28, 44, 28, 12]
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(.fg0)
                    .frame(width: 6, height: heights[index])
            }
        }
        .frame(width: 116, height: 116)
        #if os(macOS)
            .ccFlatCircle()
        #else
            .glassEffect(.regular, in: .circle)
        #endif
    }

    @ViewBuilder
    private func connectButton() -> some View {
        AsyncButton {
            // 连的是**所有勾选在线的房间**，不是当前这一个。
            // 并发连，不排队 —— 六个房间串行连最后一个要等很久。
            await rooms.startAll()
        } label: {
            Text(verbatim: "开始通话")
                .matchedGeometryEffect(id: "connect", in: button)
                .frame(maxWidth: .infinity)
                .frame(height: Self.controlHeight)
        } busyLabel: {
            HStack(spacing: CC.Space.snug) {
                ProgressView()
                    .tint(.white)
                    .transition(.scale.combined(with: .opacity))
                Text(verbatim: "正在连接")
                    .matchedGeometryEffect(id: "connect", in: button)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.controlHeight)
        }
        // ⭐ **主操作不用品牌色，用近黑实心胶囊。**
        //    Chris 2026-09-21 拿 Perplexity 登录页当参照定的。
        //    完整理由写在 `CCPrimaryButtonStyle` 上 —— 一句话：
        //    **强调色靠稀缺生效，铺在最大的那块上它就不再是强调色了。**
        //
        //    ⚠️ 这里**不再分平台**。上一版 Mac 走 `.borderedProminent`、
        //    iOS 走 `.glassProminent`，那是「各自跟随平台默认」的思路；
        //    现在是「这颗按钮该长什么样」由我们定，两个平台长一样才对 ——
        //    否则同一个 app 在两台设备上主操作是两个颜色。
        .buttonStyle(CCPrimaryButtonStyle())
    }

    /// 进谁的房间。
    ///
    /// 一个 bot 一个常驻房间，房间名就是 bot 名 —— 所以点开这里实际上是在问
    /// 「要跟哪个助理说话」。开的是和连接之后那个汉堡菜单**同一个**抽屉：
    /// 选房间这件事在会话前后是一回事，没道理做两套界面、两份状态。
    private func roomPicker() -> some View {
        Button {
            roomsPresented = true
        } label: {
            HStack(spacing: CC.Space.snug) {
                Image(systemName: "person.wave.2.fill")
                    .foregroundStyle(.fgAccent)
                Text(verbatim: config.room.isEmpty ? "挑一个房间" : config.room)
                    .foregroundStyle(.fg0)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.fg3)
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, CC.Space.regular)
            .frame(height: Self.controlHeight)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        #if os(macOS)
            .ccFlatBar(radius: CC.Radius.bar)
        #else
            .glassEffect(.regular.interactive(), in: .cc(CC.Radius.bar))
        #endif
        .sheet(isPresented: $roomsPresented) {
            CCRoomListView()
        }
    }

    private func settingsButton() -> some View {
        Button {
            settingsPresented = true
        } label: {
            HStack(spacing: CC.Space.tight) {
                Image(systemName: "gearshape")
                Text(verbatim: "设置")
            }
            .font(.subheadline)
            .foregroundStyle(.fg3)
            .padding(.horizontal, CC.Space.regular)
            .frame(height: CC.Size.tapTarget)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // Mac 走 ⌘, 那个独立窗口，其它平台弹 sheet。见 CCSettingsPresenter。
        .ccSettingsSheet(isPresented: $settingsPresented)
    }
}

#Preview {
    StartView()
}
