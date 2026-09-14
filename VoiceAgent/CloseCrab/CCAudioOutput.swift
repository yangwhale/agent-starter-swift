import AVFoundation
import SwiftUI
#if os(iOS) || os(visionOS) || os(tvOS)
    import AVKit
#endif

/// 输出设备选择 —— **直接用系统的路由选择器，不自己列设备**。
///
/// 这是抄 Discord 的作业。Chris 09-14 发来的 Discord 截图里那个「iPhone / 扬声器 /
/// Chris-AirPods3（左 95%）」的列表**不是 Discord 画的**，是 iOS 自带的路由选择器：
/// 弹窗顶上有 app 图标和音量条、AirPods 还带电量，全是系统给的。Discord 只是在
/// 工具栏放了一个按钮去唤起它。
///
/// 所以我们也这么做，好处不只是省事：
///
/// - **枚举不了的东西它能枚举。** 输入设备那一头 iOS 根本不让 app 自由切换
///   （LiveKit SDK 的 `inputDevices` 整个包在 `#if os(macOS)` 里），
///   但输出这一头苹果给了官方入口，AirPlay、各种蓝牙、车机全在里面。
/// - **不用跟着系统更新跑。** 新出的设备类型、新的电量显示，系统自己会加。
///
/// ⚠️ 能列出哪些路由**跟语音处理模式有关**：选 Platform（苹果语音处理）时，
/// 系统会主动收窄可用路由 —— 苹果文档原话是「reduces the set of allowed audio
/// routes to only those suitable for voice chat」。所以同一部手机在 Platform 和
/// Software 两种模式下，这个列表长得可能不一样。**那不是 bug。**
enum CCAudioOutput {
    /// 当前输出口的名字，例如「Chris-AirPods3」「扬声器」「iPhone」。
    static var currentName: String {
        #if os(macOS)
            return ""
        #else
            return AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? ""
        #endif
    }

    /// 给当前输出口挑一个图标。判断依据是端口类型，不是名字 ——
    /// 名字是用户自己起的（"Chris-AirPods3"），拿它做匹配迟早出错。
    static var currentSymbol: String {
        #if os(macOS)
            return "speaker.wave.2.fill"
        #else
            guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
                return "speaker.slash.fill"
            }
            switch port.portType {
            case .builtInSpeaker: return "speaker.wave.2.fill"
            case .builtInReceiver: return "iphone"
            case .headphones, .headsetMic: return "headphones"
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return "airpodspro"
            case .carAudio: return "car.fill"
            case .airPlay: return "airplayaudio"
            case .HDMI, .usbAudio: return "cable.connector"
            default: return "speaker.wave.2.fill"
            }
        #endif
    }
}

/// 把系统路由选择器**透明地盖在**我们自己画的按钮上。
///
/// `AVRoutePickerView` 本身就是一个按钮，样式基本改不动（只能调 tint）。
/// 想要跟控制栏其余按钮长一样，唯一的办法是自己画一个好看的，
/// 然后把它铺在上面负责接点击 —— 这是 iOS 上的标准做法，不是 hack。
#if os(iOS) || os(visionOS) || os(tvOS)
    private struct RoutePickerOverlay: UIViewRepresentable {
        func makeUIView(context _: Context) -> AVRoutePickerView {
            let view = AVRoutePickerView()
            // 我们只有音频。不关掉的话，列表会优先推 Apple TV 这类视频接收端，
            // 把真正想选的耳机挤到下面去。
            view.prioritizesVideoDevices = false
            // 整个控件透明，真正显示的是底下我们自己那层。
            view.tintColor = .clear
            view.activeTintColor = .clear
            return view
        }

        func updateUIView(_: AVRoutePickerView, context _: Context) {}
    }
#endif

/// 控制栏上那颗「从哪儿播」按钮。点一下弹出系统路由选择器。
struct CCAudioOutputButton: View {
    var height: CGFloat

    @State private var symbol = CCAudioOutput.currentSymbol
    @State private var name = CCAudioOutput.currentName

    var body: some View {
        content
        #if os(iOS) || os(visionOS) || os(tvOS)
        // 路由变了要立刻换图标。**不能只在出现时读一次** ——
        // 摘下 AirPods 的那一刻按钮还画着耳机，是那种「看着没坏」的坏。
        .onReceive(NotificationCenter.default.publisher(
            for: AVAudioSession.routeChangeNotification)) { _ in
                symbol = CCAudioOutput.currentSymbol
                name = CCAudioOutput.currentName
            }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS) || os(visionOS) || os(tvOS)
            ZStack {
                label
                RoutePickerOverlay()
                    .frame(width: 44, height: height)
                    .contentShape(Rectangle())
            }
            .frame(height: height)
        #else
            // macOS 上输出设备由系统设置管，这里不画按钮。
            EmptyView()
        #endif
    }

    private var label: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .frame(height: height)
            .padding(.horizontal, 2 * .grid)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(verbatim: "输出：\(name.isEmpty ? "未知" : name)"))
    }
}
