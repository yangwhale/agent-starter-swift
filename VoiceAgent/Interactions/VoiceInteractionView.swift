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
            // 「按住说话」原来铺在这片中间区域上，现在挪到底部长条了 ——
            // 它用 DragGesture(minimumDistance: 0)，手指一落下就把手势吃掉，
            // 而这片区域现在要留给左右滑动切 bot，两者不能共存。
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
