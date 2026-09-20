import LiveKitComponents

/// A view that shows the local participant's camera view with flip control.
struct LocalParticipantView: View {
    @EnvironmentObject private var localMedia: LocalMedia

    @Environment(\.namespace) private var namespace
    /// 几何 id 按页分区。**多房间分页时不分区会跨页撞 id**，见 `geoScope` 的注释。
    @Environment(\.geoScope) private var geoScope

    var body: some View {
        if let cameraTrack = localMedia.cameraTrack {
            SwiftUIVideoView(cameraTrack)
                .clipShape(RoundedRectangle(cornerRadius: .cornerRadiusPerPlatform))
                .aspectRatio(cameraTrack.aspectRatio, contentMode: .fit)
                .shadow(radius: 20, y: 10)
                .transition(.scale.combined(with: .opacity))
                .overlay(alignment: .bottomTrailing) {
                    if localMedia.canSwitchCamera {
                        AsyncButton(action: localMedia.switchCamera) {
                            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                                .padding(2 * .grid)
                                .foregroundStyle(.fg0)
                                .background(.bg1.opacity(0.8))
                                .clipShape(Circle())
                        }
                        .padding(2 * .grid)
                    }
                }
                .matchedGeometryEffect(id: "camera-\(geoScope)", in: namespace!)
        }
    }
}
