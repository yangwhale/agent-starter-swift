import SwiftUI

/// A view that shows an error snackbar.
struct ErrorView: View {
    let error: Error
    /// 哪个房间出的错。多房间之后「出错了」三个字不够用 ——
    /// 屏幕上同时挂着四个房间，不说是谁，这条提示等于没说。
    var room: String? = nil
    /// app 还在后台自动重试时补一句（「还在自动重试：第 N 次，X 秒后」）。
    var retryNote: String? = nil
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 2 * .grid) {
            HStack(spacing: 2 * .grid) {
                Image(systemName: "exclamationmark.triangle")
                Text(verbatim: room.map { "\($0) 连不上" } ?? "出错了")
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 15, weight: .semibold))

            Text(error.localizedDescription)
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: .leading)

            // ⛔ 这里原来对「timed out」补一句「多半是同时连好几个房间挤在一起了」。
            //    2026-10-05 那次真因是 jarvis 正在重启，这句话把人往错的方向带 ——
            //    **猜不准的原因不如不说**。现在只说事实：app 还在不在自己重试。
            if let retryNote {
                Text(verbatim: retryNote)
                    .font(.system(size: 13))
                    .opacity(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(3 * .grid)
        .background(.bgSerious)
        .foregroundStyle(.fgSerious)
        .clipShape(RoundedRectangle(cornerRadius: .cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: .cornerRadiusSmall)
                .stroke(.separatorSerious, lineWidth: 1)
        )
        .safeAreaPadding(4 * .grid)
    }
}

#Preview {
    ErrorView(
        error: NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Sample error message"]),
        onDismiss: {}
    )
}
