import SwiftUI

/// 服务器 / 密钥 / 房间列表。
///
/// 这些全是**部署形态**，不是代码：换个入口、加个 bot、轮换一次密钥，
/// 都不该变成一次重新编译 + 重新签名 + 重新装机。
struct CloseCrabSettingsView: View {
    @ObservedObject private var config = CloseCrabConfig.shared
    @ObservedObject private var directory = CCRoomDirectory.shared
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
                    Text(verbatim: "会去请求 <这个地址>/api/token 和 /api/rooms。原生 app 没有浏览器的登录 cookie，所以这里必须是 /native 那条不走 IAP 的入口。")
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
                    SecureField(text: $config.sharedSecret, prompt: Text(verbatim: "必填，对应后端的 CC_NATIVE_SECRET")) {
                        Text(verbatim: "密钥")
                    }
                } header: {
                    Text(verbatim: "共享密钥")
                } footer: {
                    Text(verbatim: "存在 Keychain 里，不上网。每次请求只发一个 HMAC 签名和时间戳。不填的话 /native 那条路会回 401。签名带秒级时间戳，服务端只收 ±300 秒，所以设备时钟得是准的。")
                }

                // 这里**不给编辑**。以前是一串手写的逗号分隔文本，加一个 bot 就得
                // 把每台设备挨个改一遍；现在名单由服务端的 ALLOWED_ROOMS 说了算，
                // 这一段只是让人确认「app 这边看到的是什么」。
                Section {
                    if directory.rooms.isEmpty {
                        Text(verbatim: "还没拉到名单")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(directory.rooms) { room in
                            HStack {
                                Text(verbatim: room.name)
                                Spacer()
                                if room.name == config.room {
                                    Text(verbatim: "当前")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Button {
                        Task { await directory.refresh() }
                    } label: {
                        HStack {
                            Text(verbatim: "重新拉取")
                            Spacer()
                            if directory.isRefreshing {
                                ProgressView()
                                    #if !os(macOS)
                                        .controlSize(.small)
                                    #endif
                            }
                        }
                    }
                    .disabled(directory.isRefreshing)
                } header: {
                    Text(verbatim: "房间列表")
                } footer: {
                    if let error = directory.lastError {
                        Text(verbatim: "上次拉取失败，显示的是缓存：\(error)")
                            .foregroundStyle(.orange)
                    } else {
                        Text(verbatim: "从 <服务器>/api/rooms 拉，和后端换 token 用的是同一份白名单，所以不会出现「这里列得出、那里连不上」。")
                    }
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
