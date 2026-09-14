import LiveKitComponents
import SwiftUI

/// The initial view that is shown when the app is not connected to the server.
struct StartView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var rooms: CCRooms
    @ObservedObject private var config = CloseCrabConfig.shared

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var button

    @State private var audioOptionsPresented = false
    @State private var settingsPresented = false
    @State private var roomsPresented = false

    var body: some View {
        VStack(spacing: 8 * .grid) {
            bars()
            roomPicker()
            connectButton()
            HStack(spacing: 8 * .grid) {
                audioOptionsButton()
                settingsButton()
            }
        }
        .padding(.horizontal, horizontalSizeClass == .regular ? 32 * .grid : 16 * .grid)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, content: tip)
        #if os(visionOS)
            .glassBackgroundEffect()
            .frame(maxWidth: 175 * .grid)
        #endif
    }

    private func bars() -> some View {
        HStack(spacing: .grid) {
            let bars = [2, 8, 12, 8, 2].map { $0 * .grid }
            ForEach(0 ..< 5, id: \.self) { index in
                Rectangle()
                    .fill(.fg0)
                    .frame(width: 2 * .grid, height: bars[index])
            }
        }
    }

    private func tip() -> some View {
        VStack(spacing: 2 * .grid) {
            #if targetEnvironment(simulator)
                Text("connect.simulator")
                    .foregroundStyle(.fgModerate)
            #endif
            Text("connect.tip")
                .foregroundStyle(.fg3)
        }
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
        .safeAreaPadding(.horizontal, horizontalSizeClass == .regular ? 32 * .grid : 16 * .grid)
        .safeAreaPadding(.vertical)
    }

    @ViewBuilder
    private func connectButton() -> some View {
        AsyncButton {
            // 连的是**所有勾选在线的房间**，不是当前这一个。
            // 并发连，不排队 —— 六个房间串行连最后一个要等很久。
            await rooms.startAll()
        } label: {
            HStack {
                Spacer()
                Text("connect.start")
                    .matchedGeometryEffect(id: "connect", in: button)
                Spacer()
            }
            .frame(width: 58 * .grid, height: 11 * .grid)
        } busyLabel: {
            HStack(spacing: 4 * .grid) {
                Spacer()
                Spinner()
                    .transition(.scale.combined(with: .opacity))
                Text("connect.connecting")
                    .matchedGeometryEffect(id: "connect", in: button)
                Spacer()
            }
            .frame(width: 58 * .grid, height: 11 * .grid)
        }
        #if os(visionOS)
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        #else
        .buttonStyle(ProminentButtonStyle())
        #endif
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
            HStack(spacing: 2 * .grid) {
                Image(systemName: "person.wave.2.fill")
                Text(verbatim: config.room.isEmpty ? "挑一个房间" : config.room)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.fg3)
            }
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.fg0)
            .frame(width: 58 * .grid, height: 9 * .grid)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $roomsPresented) {
            CCRoomListView()
        }
    }

    private func settingsButton() -> some View {
        Button {
            settingsPresented = true
        } label: {
            HStack(spacing: .grid) {
                Image(systemName: "gearshape")
                Text(verbatim: "服务器")
            }
            .font(.system(size: 13))
            .foregroundStyle(.fg3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $settingsPresented) {
            CloseCrabSettingsView()
        }
    }

    private func audioOptionsButton() -> some View {
        Button {
            audioOptionsPresented = true
        } label: {
            HStack(spacing: .grid) {
                Image(systemName: "slider.horizontal.3")
                Text("audio.title")
            }
            .font(.system(size: 13))
            .foregroundStyle(.fg3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $audioOptionsPresented) {
            AudioOptionsSheet()
        }
    }
}

#Preview {
    StartView()
}
