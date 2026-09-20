import LiveKitComponents
import SwiftUI

/// The initial view that is shown when the app is not connected to the server.
struct StartView: View {
    @EnvironmentObject private var session: Session
    @Environment(CCRooms.self) private var rooms
    @ObservedObject private var config = CloseCrabConfig.shared

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var button

    @State private var settingsPresented = false
    @State private var roomsPresented = false

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, horizontalSizeClass == .regular ? CC.Space.section * 2 : CC.Space.screen)
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
        .glassEffect(.regular, in: .circle)
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
                .frame(height: CC.Size.talkBar)
        } busyLabel: {
            HStack(spacing: CC.Space.snug) {
                ProgressView()
                    .tint(.white)
                    .transition(.scale.combined(with: .opacity))
                Text(verbatim: "正在连接")
                    .matchedGeometryEffect(id: "connect", in: button)
            }
            .frame(maxWidth: .infinity)
            .frame(height: CC.Size.talkBar)
        }
        .font(.headline)
        // 主操作用 prominent 玻璃：它自带染色、按压形变和无障碍对比度处理，
        // 比自己拿一个蓝色矩形加圆角要「像系统的东西」。
        .buttonStyle(.glassProminent)
        .tint(.fgAccent)
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
            .frame(height: CC.Size.talkBar)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .cc(CC.Radius.bar))
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
        .sheet(isPresented: $settingsPresented) {
            CloseCrabSettingsView()
        }
    }
}

#Preview {
    StartView()
}
