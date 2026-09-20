import LiveKitComponents

/// A multiplatform view that shows the control bar: audio/video and chat controls.
/// Available controls depend on the agent features and the track availability.
/// - SeeAlso: ``AgentFeatures``
struct ControlBar: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var localMedia: LocalMedia
    @Environment(CCRooms.self) private var rooms

    @Binding var chat: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.voiceEnabled) private var voiceEnabled
    @Environment(\.videoEnabled) private var videoEnabled
    @Environment(\.textEnabled) private var textEnabled


    private enum Constants {
        static let buttonWidth: CGFloat = CC.Size.tapTarget
        static let buttonHeight: CGFloat = CC.Size.tapTarget
    }

    var body: some View {
        HStack(spacing: .zero) {
            biggerSpacer()
            if voiceEnabled {
                audioControls()
                flexibleSpacer()
                // 「从哪儿播」——抄 Discord 的作业，用系统路由选择器。
                // 放在麦克风旁边：输入输出挨着，不用满屏找。
                outputControls()
                flexibleSpacer()
            }
            if videoEnabled {
                videoControls()
                flexibleSpacer()
                screenShareButton()
                flexibleSpacer()
            }
            if textEnabled {
                textInputButton()
                flexibleSpacer()
            }
            disconnectButton()
            biggerSpacer()
        }
        .buttonStyle(
            ControlBarButtonStyle(
                foregroundColor: .fg1,
                backgroundColor: .bg2,
                borderColor: .separator1
            )
        )
        .font(.system(size: 17, weight: .medium))
        .frame(height: CC.Size.controlBar)
        #if !os(visionOS)
            // 一整条就是一块玻璃，按钮本身不再各带背景 —— 这是系统标签栏
            // 和 App Store 底栏的做法。原来那套「描边 + 实心底 + 投影」
            // 是 Liquid Glass 之前的语言，摆在 iOS 26 上一眼是上个时代的。
            // `.clear` 不是 `.regular`：后者会往玻璃里掺一层自适应的底色，
            // 保证任何背景下文字都读得出来 —— 代价是背后那张图基本透不过来，
            // 看着就是一条浅灰长条。`.clear` 是 Apple 专门给「背后是图片/视频」
            // 的场景准备的变体，几乎只剩折射和边缘高光。
            // 我们现在背后是整张背景图，正是它的适用场景。
            .glassEffect(.clear, in: .cc(CC.Radius.bar))
        #endif
    }

    private func flexibleSpacer() -> some View {
        Spacer()
            .frame(maxWidth: horizontalSizeClass == .regular ? 8 * .grid : 2 * .grid)
    }

    private func biggerSpacer() -> some View {
        Spacer()
            .frame(maxWidth: horizontalSizeClass == .regular ? 8 * .grid : .infinity)
    }

    private func separator() -> some View {
        Rectangle()
            .fill(.separator1)
            .frame(width: 1, height: 3 * .grid)
    }

    private func audioControls() -> some View {
        HStack(spacing: .zero) {
            Spacer()
            AsyncButton(action: localMedia.toggleMicrophone) {
                HStack(spacing: .grid) {
                    Image(systemName: localMedia.isMicrophoneEnabled ? "microphone.fill" : "microphone.slash.fill")
                        .transition(.symbolEffect)
                    BarAudioVisualizer(
                        audioTrack: localMedia.microphoneTrack,
                        barColor: .fg1,
                        barCount: 3,
                        barSpacingFactor: 0.1
                    )
                    .frame(width: 2 * .grid, height: 0.5 * Constants.buttonHeight)
                    .frame(maxHeight: .infinity)
                    .id(localMedia.microphoneTrack?.id)
                }
                .frame(height: Constants.buttonHeight)
                .padding(.horizontal, 2 * .grid)
                                    .contentShape(Rectangle())
                    // 逐颗按钮的触摸反馈。`.identity` = **静止时完全不改变外观**，
                    // 手指落下才浮出形变和高光。
                    //
                    // 为什么要逐颗加而不是靠整条那块玻璃：整条只有一块，按哪儿
                    // 都没有局部反馈。而 Tide Guide 那位开发者在 Apple 官方 session
                    // 里专门讲了这一条 —— **小按钮被手指盖住时，你得抬手才知道按没按中**，
                    // 加了交互玻璃就变成落指即有反应。控制栏这几颗正是那种尺寸。
                    .glassEffect(.identity.interactive(), in: .capsule)
            }
            #if os(macOS)
                separator()
                AudioDeviceSelector()
                    .frame(height: Constants.buttonHeight)
            #endif
            Spacer()
        }
        .frame(width: Constants.buttonWidth)
    }

    /// 输出设备。macOS 上系统设置里管，`CCAudioOutputButton` 自己会退成空视图，
    /// 所以这里不用再包一层 `#if`。
    private func outputControls() -> some View {
        CCAudioOutputButton(height: Constants.buttonHeight)
            .frame(width: Constants.buttonWidth)
    }

    private func videoControls() -> some View {
        HStack(spacing: .zero) {
            Spacer()
            AsyncButton {
                await localMedia.toggleCamera(disableScreenShare: true)
            } label: {
                Image(systemName: localMedia.isCameraEnabled ? "video.fill" : "video.slash.fill")
                    .transition(.symbolEffect)
                    .frame(height: Constants.buttonHeight)
                    .padding(.horizontal, 2 * .grid)
                                        .contentShape(Rectangle())
                    // 逐颗按钮的触摸反馈。`.identity` = **静止时完全不改变外观**，
                    // 手指落下才浮出形变和高光。
                    //
                    // 为什么要逐颗加而不是靠整条那块玻璃：整条只有一块，按哪儿
                    // 都没有局部反馈。而 Tide Guide 那位开发者在 Apple 官方 session
                    // 里专门讲了这一条 —— **小按钮被手指盖住时，你得抬手才知道按没按中**，
                    // 加了交互玻璃就变成落指即有反应。控制栏这几颗正是那种尺寸。
                    .glassEffect(.identity.interactive(), in: .capsule)
            }
            #if os(macOS)
                separator()
                VideoDeviceSelector()
                    .frame(height: Constants.buttonHeight)
            #endif
            Spacer()
        }
        .frame(width: Constants.buttonWidth)
        .disabled(!session.agent.isConnected)
    }

    private func screenShareButton() -> some View {
        AsyncButton {
            await localMedia.toggleScreenShare(disableCamera: true)
        } label: {
            Image(systemName: "arrow.up.square.fill")
                .frame(width: Constants.buttonWidth, height: Constants.buttonHeight)
                                    .contentShape(Rectangle())
                    // 逐颗按钮的触摸反馈。`.identity` = **静止时完全不改变外观**，
                    // 手指落下才浮出形变和高光。
                    //
                    // 为什么要逐颗加而不是靠整条那块玻璃：整条只有一块，按哪儿
                    // 都没有局部反馈。而 Tide Guide 那位开发者在 Apple 官方 session
                    // 里专门讲了这一条 —— **小按钮被手指盖住时，你得抬手才知道按没按中**，
                    // 加了交互玻璃就变成落指即有反应。控制栏这几颗正是那种尺寸。
                    .glassEffect(.identity.interactive(), in: .capsule)
        }
        .buttonStyle(
            ControlBarButtonStyle(
                isToggled: localMedia.isScreenShareEnabled,
                foregroundColor: .fg1,
                backgroundColor: .bg2,
                borderColor: .separator1
            )
        )
        .disabled(!session.agent.isConnected)
    }

    private func textInputButton() -> some View {
        Button {
            chat.toggle()
        } label: {
            Image(systemName: "ellipsis.message.fill")
                .frame(width: Constants.buttonWidth, height: Constants.buttonHeight)
                                    .contentShape(Rectangle())
                    // 逐颗按钮的触摸反馈。`.identity` = **静止时完全不改变外观**，
                    // 手指落下才浮出形变和高光。
                    //
                    // 为什么要逐颗加而不是靠整条那块玻璃：整条只有一块，按哪儿
                    // 都没有局部反馈。而 Tide Guide 那位开发者在 Apple 官方 session
                    // 里专门讲了这一条 —— **小按钮被手指盖住时，你得抬手才知道按没按中**，
                    // 加了交互玻璃就变成落指即有反应。控制栏这几颗正是那种尺寸。
                    .glassEffect(.identity.interactive(), in: .capsule)
        }
        .buttonStyle(
            ControlBarButtonStyle(
                isToggled: chat,
                foregroundColor: .fg1,
                backgroundColor: .bg2,
                borderColor: .separator1
            )
        )
        .disabled(!session.agent.isConnected)
    }

    private func disconnectButton() -> some View {
        AsyncButton {
            // 挂断挂全部。只挂当前那个的话，别的房间还连着、还在烧 Gemini，
            // 而界面已经回到启动页 —— 用户以为断干净了。
            await rooms.endAll()
        } label: {
            Image(systemName: "phone.down.fill")
                .frame(width: Constants.buttonWidth, height: Constants.buttonHeight)
                                    .contentShape(Rectangle())
                    // 逐颗按钮的触摸反馈。`.identity` = **静止时完全不改变外观**，
                    // 手指落下才浮出形变和高光。
                    //
                    // 为什么要逐颗加而不是靠整条那块玻璃：整条只有一块，按哪儿
                    // 都没有局部反馈。而 Tide Guide 那位开发者在 Apple 官方 session
                    // 里专门讲了这一条 —— **小按钮被手指盖住时，你得抬手才知道按没按中**，
                    // 加了交互玻璃就变成落指即有反应。控制栏这几颗正是那种尺寸。
                    .glassEffect(.identity.interactive(), in: .capsule)
        }
        .buttonStyle(
            ControlBarButtonStyle(
                foregroundColor: .fgSerious,
                backgroundColor: .bgSerious,
                borderColor: .separatorSerious
            )
        )
        .disabled(!rooms.isAnyConnected)
    }
}
