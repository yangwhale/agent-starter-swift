import SwiftUI

/// A multiplatform view that shows voice-specific interaction controls.
///
/// Depending on the track availability, the view will show:
/// - agent participant view
/// - local participant camera preview
/// - local participant screen share preview
///
/// - Note: The layout is determined by the horizontal size class.
struct VoiceInteractionView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            regular()
        } else {
            compact()
        }
    }

    private func regular() -> some View {
        HStack {
            Spacer()
                .frame(width: 50 * .grid)
            AgentView()
            VStack {
                Spacer()
                ScreenShareView()
                LocalParticipantView()
            }
            .frame(width: 50 * .grid)
        }
        .safeAreaPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compact() -> some View {
        ZStack(alignment: .bottom) {
            AgentView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            // 中间这片本来什么都干不了 —— 铺成「按住说话」。
            // 压在 AgentView 上面、在下面那排预览下面：按住区要能接到点击，
            // 但不能挡住摄像头/屏幕共享的小窗。
            CCHoldToTalkArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Spacer()
                ScreenShareView()
                LocalParticipantView()
            }
            .frame(height: 50 * .grid)
            .safeAreaPadding()
        }
    }
}
