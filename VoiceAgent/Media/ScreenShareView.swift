import LiveKitComponents

/// A view that shows the screen share preview.
struct ScreenShareView: View {
    @EnvironmentObject private var localMedia: LocalMedia

    @Environment(\.namespace) private var namespace
    /// 几何 id 按页分区。**多房间分页时不分区会跨页撞 id**，见 `geoScope` 的注释。
    @Environment(\.geoScope) private var geoScope

    var body: some View {
        if let screenShareTrack = localMedia.screenShareTrack {
            SwiftUIVideoView(screenShareTrack)
                .clipShape(RoundedRectangle(cornerRadius: .cornerRadiusPerPlatform))
                .aspectRatio(screenShareTrack.aspectRatio, contentMode: .fit)
                .shadow(radius: 20, y: 10)
                .transition(.scale.combined(with: .opacity))
                .matchedGeometryEffect(id: "screen-\(geoScope)", in: namespace!)
        }
    }
}
