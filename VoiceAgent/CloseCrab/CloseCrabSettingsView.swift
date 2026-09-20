import SwiftUI

/// 服务器 / 密钥 / 房间列表。
///
/// 这些全是**部署形态**，不是代码：换个入口、加个 bot、轮换一次密钥，
/// 都不该变成一次重新编译 + 重新签名 + 重新装机。
struct CloseCrabSettingsView: View {
    /// 设置页要**双向绑定**（`$config.xxx`），所以用 `@Bindable` 而不是裸属性。
    @Bindable private var config = CloseCrabConfig.shared
    private var directory: CCRoomDirectory { .shared }
    @Environment(\.dismiss) private var dismiss
    /// 数字人那一路。**读单例不用 `@EnvironmentObject`** —— 后者忘了注入是
    /// 运行时崩溃而不是编译错误，而下面那个 `#Preview` 必然注入不了。
    private var avatar: CCAvatarLink { .shared }

    #if os(macOS)
        /// 读单例。**这里用单例是对的**：底下那个全局事件监听本来就只该有一个，
        /// 两个实例会重复注册、同一次按键触发两遍。
        /// 而设置页是 sheet（关掉就没了），从它去持有生命周期更长的东西才是错的。
        private var macHotkey: CCMacHotkey { .shared }
    #endif

    var body: some View {
        NavigationStack {
            Form {
                // 外观放最上面：这是唯一一组「想起来就会去调一下」的设置。
                // 下面那几段（服务器、密钥、信令）是装一次就再也不碰的东西。
                #if os(macOS)
                    Section {
                        Picker(selection: $config.pushToTalkKey) {
                            ForEach(CCPushToTalkKey.allCases) { key in
                                Text(verbatim: key.label).tag(key)
                            }
                        } label: {
                            Text(verbatim: "按住说话")
                        }

                        if let warning = config.pushToTalkKey.warning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }

                        // ⚠️ 这一段不能省。没授权时全局按键**静默不工作** ——
                        // 用户只会觉得"坏了"，而真相只是没点那个系统开关。
                        // 静默失败比报错难查十倍，所以状态必须摆在明面上。
                        do {
                            let hotkey = macHotkey
                            Text(verbatim: hotkey.statusText)
                                .font(.footnote)
                                .foregroundStyle(hotkey.isTrusted ? Color.secondary : Color.orange)
                            if !hotkey.isTrusted {
                                Button("去系统设置里授权…") {
                                    hotkey.requestTrust()
                                    hotkey.openAccessibilitySettings()
                                }
                            }
                        }
                    } header: {
                        Text(verbatim: "键盘")
                    } footer: {
                        Text(verbatim: "全局按键要「辅助功能」权限；没授权也能用 —— "
                            + "窗口在前台时按住空格即可。")
                    }
                #endif

                Section {
                    Picker(selection: $config.backdrop) {
                        ForEach(CCBackdropChoice.allCases) { choice in
                            Text(verbatim: choice.label).tag(choice)
                        }
                    } label: {
                        Text(verbatim: "背景")
                    }
                    #if os(iOS)
                    .pickerStyle(.menu)
                    #endif

                    Picker(selection: $config.appearance) {
                        ForEach(CCAppearance.allCases) { mode in
                            Text(verbatim: mode.label).tag(mode)
                        }
                    } label: {
                        Text(verbatim: "深浅色")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(verbatim: "外观")
                } footer: {
                    Text(verbatim: backdropFooter)
                }

                Section {
                    Toggle(isOn: $config.handwritten) {
                        Text(verbatim: "房间名用手写体")
                    }
                    .disabled(!CCHandFont.isAvailable)

                    #if os(iOS)
                        Toggle(isOn: $config.haptics) {
                            Text(verbatim: "手势震动")
                        }
                    #endif
                } header: {
                    Text(verbatim: "细节")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if CCHandFont.isAvailable {
                            Text(verbatim: "手写体只作用在房间名和「没设过图标时显示的首字母」上，其余一律不动。字库里没有中文，中文会自动回退到系统字。")
                        } else {
                            // 字体没装上时**必须说出来**：Font.custom 找不到字体
                            // 不会报错，会安静地退回系统字。不说的话用户看到的是
                            // 一个拨了没反应的开关，只会以为是 app 坏了。
                            Text(verbatim: "手写体没能加载：\(CCHandFont.lastNote)")
                                .foregroundStyle(.orange)
                        }
                        #if os(iOS)
                            Text(verbatim: "震动：切房间轻轻一下，静音重一点，长按换图标是软的一下；双击一个还没连上的方块会给一记「不行」。")
                        #endif
                    }
                }

                // ⚠️ Avatar 开关**不在设置页里了**（2026-09-18）。
                //    它现在是「每个房间、每个角色」一个，界面在房间顶上那排
                //    牌子上：双击本人 / 双击语音助手。理由见 `CCAvatarRoles.swift`
                //    ——一个全局布尔表达不了「给谁」，而房间里有两路声音。
                //
                //    只留下面这条上报失败：那是**静默**的（服务端读不到属性，
                //    现象就是「双击了没反应」），牌子上那个标记只能说明
                //    本地状态，说明不了报上去没有。



                Section {
                    Toggle(isOn: $config.netReadout) {
                        Text(verbatim: "显示网络读数")
                    }
                    #if os(iOS) || os(visionOS)
                    Toggle(isOn: $config.releaseMicWhenIdle) {
                        Text(verbatim: "不说话时让出麦克风")
                    }
                    #endif
                } header: {
                    Text(verbatim: "排障")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "在控制栏上方显示抖动缓冲深度和丢包率。信号差时用来分辨是「缓冲没涨上去」还是「整段断流」—— 这两种听起来一模一样，但处理方式完全相反。平时建议关掉。")
                        Text(verbatim: "Avatar 开关在房间里那排牌子上：双击「本人」或「语音助手」开关，开着的那个名字后面会有一个小屏幕标记。")
                        #if os(iOS) || os(visionOS)
                        Text(verbatim: "「让出麦克风」开着时，闭麦期间别的 App（比如语音输入法）能立刻拿到麦克风；代价是重新开口说话要多等一下引擎重启。关掉它会退回 LiveKit 原来的行为 —— 只要这次连接里录过一次音，麦克风就一直被占着直到断开。改完要重启 App 才生效。")
                        #endif
                        if let err = avatar.lastPublishError {
                            Text(verbatim: "Avatar 开关没能报给服务端：\(err)")
                                .foregroundStyle(.orange)
                        }
                    }
                }

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

                // 语音处理放在设置里而不是通话界面：它描述的是「这台设备的麦克风
                // 怎么处理声音」，跟你在跟谁说话没关系，也不是一个需要边说边调的东西。
                // 原来挂在控制栏麦克风旁边那个小箭头里，等于把一个装一次就不用再碰的
                // 开关摆在最显眼的位置，还每个房间各调一次。
                Section {
                    Picker(selection: $config.voiceProcessing) {
                        Text(verbatim: "软件（WebRTC）").tag(VoiceProcessingMode.software)
                        Text(verbatim: "系统（Apple）").tag(VoiceProcessingMode.platform)
                        Text(verbatim: "自动").tag(VoiceProcessingMode.automatic)
                    } label: {
                        Text(verbatim: "实现")
                    }
                    #if os(iOS)
                    .pickerStyle(.menu)
                    #endif
                } header: {
                    Text(verbatim: "语音处理")
                } footer: {
                    Text(modeFooter)
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

    /// 背景那一段的说明。`auto` 要额外说清「现在是哪一段、什么时候换」——
    /// 不说的话用户看到的是一张跟自己选的选项对不上号的图。
    private var backdropFooter: String {
        // 这句「浅色模式下会淡很多」必须写出来。六张图都是暗调的，浅色模式下
        // 要让近黑的文字活下去就得提亮，提亮就吃掉对比 —— 这是物理不是 bug。
        // 不说的话，用户在浅色模式下看到的是「设了没反应」。
        let base = "背景图不只是好看：Liquid Glass 折射的是它背后的东西，背后是一块纯色的话，所有玻璃都只是半透明灰块。\n六张图都是暗调的，所以浅色模式下会淡很多 —— 想看完整效果，把上面的深浅色切到「深色」，再选「深空」或「轨道」。"
        switch config.backdrop {
        case .auto:
            let now = Calendar.current.component(.hour, from: Date())
            return base + "\n现在跟着时间走，这会儿是「\(CCSky.phase(hour: now).label)」。切换点是 05:00 / 08:00 / 16:30 / 19:30 —— 固定时钟，不算真实日出，那样要定位权限。"
        case .off:
            return base + "\n现在关着，退回原来那层极光。省一点内存，但玻璃会明显平一些。"
        default:
            return base + "\n现在锁定在「\(config.backdrop.label)」，不随时间变。"
        }
    }

    /// 每种实现干了什么。**默认是软件那一档** —— bot 的声音从扬声器出来又被
    /// 麦克风收回去，实测 WebRTC 这套消得更干净。改完立刻对所有房间生效，
    /// 不用重连。
    private var modeFooter: String {
        switch config.voiceProcessing {
        case .software:
            "WebRTC 软件处理，关掉 Apple 的那套。默认，回声消除最干净。"
            + "\n⚡️ 但它**跑在 CPU 上**，而且只在你说话时启动 —— "
            + "「一开口手机就热」多半是它。想省电就试试下面两档。"
        case .platform:
            "只用 Apple 的系统语音处理。设备不支持时会应用失败。"
            + "\n⚡️ 走专用芯片，**最省电**。代价是回声可能没软件那套消得干净 —— "
            + "bot 的声音从扬声器出来又被麦克风收回去时最容易听出差别。"
        case .automatic:
            "SDK 默认：优先 Apple，不可用时退回 WebRTC。"
            + "\n⚡️ 省电介于两者之间，但**你不知道此刻用的是哪套** —— "
            + "排查回声问题时先切到上面两档中的一个，别用这档。"
        }
    }
}

#Preview {
    CloseCrabSettingsView()
}
