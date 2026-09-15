import SwiftUI

/// A view that shows an error snackbar.
struct ErrorView: View {
    let error: Error
    /// 哪个房间出的错。多房间之后「出错了」三个字不够用 ——
    /// 屏幕上同时挂着四个房间，不说是谁，这条提示等于没说。
    var room: String? = nil
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

            // 「Connection failed: Timed out」对着用户是句废话 —— 它不说
            // 该怎么办，也不说要不要紧。补一句人话。
            //
            // 判据是**匹配错误正文里的关键词**，不是错误码：SDK 把底层错误
            // 包了两层，到这儿只剩 localizedDescription 这一个可用的信号。
            // 匹配不上就不加这一行，不硬凑。
            if error.localizedDescription.localizedCaseInsensitiveContains("timed out") {
                Text(verbatim: "多半是同时连好几个房间时挤在一起了。在房间抽屉里少勾两个，或者下拉重连一次。")
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
