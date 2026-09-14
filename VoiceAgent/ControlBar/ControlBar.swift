import LiveKitComponents

/// A multiplatform view that shows the control bar: audio/video and chat controls.
/// Available controls depend on the agent features and the track availability.
/// - SeeAlso: ``AgentFeatures``
struct ControlBar: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var localMedia: LocalMedia
    @EnvironmentObject private var rooms: CCRooms

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
            .glassEffect(.regular, in: .cc(CC.Radius.bar))
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
