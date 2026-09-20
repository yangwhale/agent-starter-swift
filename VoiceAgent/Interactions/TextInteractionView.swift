import LiveKit
import SwiftUI

/// A multiplatform view that shows text-specific interaction controls.
///
/// Depending on the track availability, the view will show:
/// - agent participant view
/// - local participant camera preview
/// - local participant screen share preview
///
/// Additionally, the view shows a complete chat view with text input capabilities.
struct TextInteractionView: View {
    /// 只为算宽度看一眼有没有数字人。**读槽位镜像，不订阅 Session** ——
    /// 后者会把这个 view 挂到「每秒几百次」的通知上，而它只关心一个有无。
    @Environment(CCRoomSlot.self) private var slot
    @EnvironmentObject private var localMedia: LocalMedia

    @FocusState.Binding var keyboardFocus: Bool

    var body: some View {
        VStack {
            VStack {
                participants()
                ChatView()
                #if os(macOS)
                    .frame(maxWidth: 128 * .grid)
                #endif
                    .blurredTop()
            }
            #if os(iOS)
            .contentShape(Rectangle())
            .onTapGesture {
                keyboardFocus = false
            }
            #endif
            ChatInputView(keyboardFocus: _keyboardFocus)
        }
    }

    private func participants() -> some View {
        HStack {
            Spacer()
            AgentView()
                .frame(maxWidth: slot.avatarVideoTrack != nil ? 50 * .grid : 25 * .grid)
            ScreenShareView()
            LocalParticipantView()
            Spacer()
        }
        .frame(
            height: localMedia.isCameraEnabled || localMedia.isScreenShareEnabled
                || slot.avatarVideoTrack != nil ? 50 * .grid : 25 * .grid
        )
        .safeAreaPadding()
    }
}
