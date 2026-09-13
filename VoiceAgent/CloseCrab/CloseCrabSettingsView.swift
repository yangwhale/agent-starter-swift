import SwiftUI

/// 服务器 / 密钥 / 房间列表。
///
/// 这些全是**部署形态**，不是代码：换个入口、加个 bot、轮换一次密钥，
/// 都不该变成一次重新编译 + 重新签名 + 重新装机。
struct CloseCrabSettingsView: View {
    @ObservedObject private var config = CloseCrabConfig.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $config.baseURL, prompt: Text(verbatim: CCStore.defaultBaseURL)) {
                        Text(verbatim: "服务器")
                    }
                    // textContentType(.URL) 只在 iOS 上存在 —— macOS 的
                    // NSTextContentType 只有用户名/密码/验证码三种，写了过不了编译。
                    #if os(iOS)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                } header: {
                    Text(verbatim: "取 token 的地址")
                } footer: {
                    Text(verbatim: "会去请求 <这个地址>/api/token?room=<房间>。原生 app 没有浏览器的登录 cookie，所以这里要填一个不在 IAP 后面的入口。")
                }

                Section {
                    TextField(text: $config.signalURL, prompt: Text(verbatim: "留空＝听服务端的")) {
                        Text(verbatim: "信令")
                    }
                    // textContentType(.URL) 只在 iOS 上存在 —— macOS 的
                    // NSTextContentType 只有用户名/密码/验证码三种，写了过不了编译。
                    #if os(iOS)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                } header: {
                    Text(verbatim: "信令地址覆盖")
                } footer: {
                    Text(verbatim: "服务端返回的 serverUrl 是给浏览器用的。手机连不上那个地址时，在这里填 wss://... 直连 SFU。")
                }

                Section {
                    SecureField(text: $config.sharedSecret, prompt: Text(verbatim: "没配就不签名")) {
                        Text(verbatim: "密钥")
                    }
                } header: {
                    Text(verbatim: "共享密钥")
                } footer: {
                    Text(verbatim: "存在 Keychain 里，不上网。每次请求只发一个 HMAC 签名和时间戳。")
                }

                Section {
                    TextField(text: $config.roomsCSV, prompt: Text(verbatim: CCStore.defaultRooms), axis: .vertical) {
                        Text(verbatim: "房间")
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                } header: {
                    Text(verbatim: "房间列表")
                } footer: {
                    Text(verbatim: "逗号分隔，房间名就是 bot 名。要和前端 ALLOWED_ROOMS 对得上，这边多写一个只会在连接时拿到 400。")
                }
            }
            .navigationTitle(Text(verbatim: "设置"))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: { Text(verbatim: "完成") }
                    }
                }
        }
    }
}

#Preview {
    CloseCrabSettingsView()
}
