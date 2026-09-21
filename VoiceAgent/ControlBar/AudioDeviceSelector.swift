import LiveKit
import SwiftUI

#if os(macOS)
    /// 麦克风输入设备菜单。
    ///
    /// **清单来自 `CCAudioInputs` 而不是 `localMedia.audioDevices`** ——
    /// 后者是建房间那一刻的快照，而且刷新它的那个回调是全局单槽、
    /// 被我们五个房间轮流覆盖、关掉任意一个还会把它置空。
    /// 完整理由写在 `CCAudioInputs` 的注释里。
    ///
    /// **切换仍然走 `localMedia.select(audioDevice:)`** —— 只有 LiveKit
    /// 能真的把输入换掉，我们自己枚举只是为了知道有哪些可选。
    struct AudioDeviceSelector: View {
        @EnvironmentObject private var localMedia: LocalMedia

        var body: some View {
            // **inline 读单例，不存成属性。** 跟 `CCRosterRow` 里
            // `CCRoomIcons.shared` 一样 —— `body` 是 `@MainActor` 的，
            // 而 View 的**存储属性初始化式不是**，把 MainActor 单例写成
            // `@State private var x = Foo.shared` 在 Swift 6 下过不去。
            // `@Observable` 的追踪只认「在 body 里读过哪些属性」，
            // 存不存成属性不影响刷新。
            let inputs = CCAudioInputs.shared

            return Menu {
                ForEach(inputs.devices, id: \.deviceId) { device in
                    Button {
                        localMedia.select(audioDevice: device)
                        // 立刻回读一次。**不等系统事件** —— 主动切设备不一定会触发
                        // `kAudioHardwarePropertyDefaultInputDevice`（系统默认设备
                        // 没变，变的是我们这个 app 用哪个），光靠监听勾选会慢半拍。
                        inputs.refresh()
                    } label: {
                        HStack {
                            Text(device.name)
                            if device.deviceId == inputs.selectedID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                // ⛔ 这里**曾经**有一行「系统有 N 个输入设备，这里只拿到 M 个」。
                //    它做完了它该做的事（证明了漏报在我们这侧、不在 WebRTC），
                //    但实测它冷启动时报的 N 是错的（说 10，真值 5）。
                //    **一个会报错数的诊断比没有诊断更坏** —— 它会被当成事实引用。
                //    对账挪进了 `[CCAudioInputs]` 日志，界面上不留。
            } label: {
                Image(systemName: "chevron.down")
                    .frame(height: 11 * .grid)
                    .font(.system(size: 12, weight: .semibold))
                    .contentShape(Rectangle())
            }
            // `Menu` 的内容不保证在弹出那一刻才求值，所以**不能等到打开再刷新**。
            // 两个时机凑起来够用：出现时来一次拿到初始清单，
            // 之后靠 `CCAudioInputs` 的系统监听自己跟着变。
            .onAppear { inputs.start() }
            // 鼠标移上来 ≈ 马上要点开。**比 onAppear 更贴近打开那一刻**，
            // 代价只有两次 CoreAudio 查询。
            .onHover { if $0 { inputs.refresh() } }
        }
    }
#endif
