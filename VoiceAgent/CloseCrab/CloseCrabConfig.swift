import SwiftUI

/// `CCStore` 的界面外衣：只负责让 SwiftUI 知道「值变了」。
/// 真正的持久化全在 `CCStore`，这里一个字段都不自己攒着 ——
/// 否则设置页改完、后台的 token source 还读着旧值，那种不一致最难看出来。
@MainActor
final class CloseCrabConfig: ObservableObject {
    static let shared = CloseCrabConfig()

    @Published var baseURL: String { didSet { CCStore.baseURL = baseURL } }
    @Published var signalURL: String { didSet { CCStore.signalURL = signalURL } }
    @Published var sharedSecret: String { didSet { CCStore.sharedSecret = sharedSecret } }
    /// 话筒现在对着谁。改它会顺带把它拉进在线名单（见 `CCStore.onlineRooms` 的不变量 2）。
    @Published var room: String { didSet { CCStore.room = room; syncOnline() } }

    /// 哪几个房间连着、听得见。**跟 `room` 是两个轴**，说明见 `CCStore.onlineRooms`。
    ///
    /// 写进去的值会被 store 规范化（丢掉已下架的、补上当前房间），所以赋值之后
    /// 立刻回读对齐一次 —— 不然界面上的勾会跟真正生效的名单对不上，
    /// 而这种不一致**看不出来**：勾是亮的，房间却没连。
    /// 显不显示网络读数。见 `CCStore.netReadout`。
    @Published var netReadout: Bool { didSet { CCStore.netReadout = netReadout } }

    // MARK: - 二分排障（临时，定位完删掉）
    //
    // 为什么有这四个开关：见 `CCStore.offStatusPanel` 上那段。
    // 一句话 —— app 静止不动也在满转烧 CPU、内存两分钟涨 883 MB，
    // 四个「不用操作就一直在跑」的组件各给一个开关，现场二分，不用反复重编。

    @Published var offStatusPanel: Bool { didSet { CCStore.offStatusPanel = offStatusPanel } }
    @Published var offRoster: Bool { didSet { CCStore.offRoster = offRoster } }
    @Published var offAgentSampler: Bool { didSet { CCStore.offAgentSampler = offAgentSampler } }
    @Published var offBackdrop: Bool { didSet { CCStore.offBackdrop = offBackdrop } }

    /// 不说话时把麦克风让出去。见 `CCStore.releaseMicWhenIdle`。
    /// **改完要重启 App 才生效。**
    @Published var releaseMicWhenIdle: Bool { didSet { CCStore.releaseMicWhenIdle = releaseMicWhenIdle } }

    @Published var onlineRooms: [String] { didSet { CCStore.onlineRooms = onlineRooms; syncOnline() } }

    /// 麦克风语音处理的实现。**全局一份**，每个房间的 `AudioOptions` 各自订阅它
    /// 往自己那条麦克风轨上应用（见 `AudioOptions.init`）。
    @Published var voiceProcessing: VoiceProcessingMode { didSet { CCStore.voiceProcessing = voiceProcessing } }

    // MARK: - 外观
    //
    // 这四个都是纯显示偏好，跟连接无关，所以不像 `room` 那样要回读对齐 ——
    // 没有任何后台任务会去改它们。

    /// 背景图。见 `CCBackdrop`。
    @Published var backdrop: CCBackdropChoice { didSet { CCStore.backdrop = backdrop } }

    /// macOS 按住说话的触发键。写死一个键等于替用户做了个他没同意的决定。
    @Published var pushToTalkKey: CCPushToTalkKey { didSet { CCStore.pushToTalkKey = pushToTalkKey } }
    /// 深浅色三档。见 `CCAppearance`。
    @Published var appearance: CCAppearance { didSet { CCStore.appearance = appearance } }
    /// 手势震动。见 `CCHaptics`。
    @Published var haptics: Bool { didSet { CCStore.haptics = haptics } }
    /// 房间名用手写体。见 `CCHandFont`。
    @Published var handwritten: Bool { didSet { CCStore.handwritten = handwritten } }

    // ⚠️ Avatar 开关**不在这里** —— 它是**每个房间、每个角色**一个，
    //    住在 `CCAvatarLink.wants(room:)`，界面在房间里那排牌子上（双击）。
    //    放全局曾经是对的（当时只有一个「要不要脸」），加了角色之后就不对了：
    //    一个全局布尔表达不了「给谁」，而房间里有两路声音。

    private init() {
        baseURL = CCStore.baseURL
        signalURL = CCStore.signalURL
        sharedSecret = CCStore.sharedSecret
        room = CCStore.room
        onlineRooms = CCStore.onlineRooms
        netReadout = CCStore.netReadout
        offStatusPanel = CCStore.offStatusPanel
        offRoster = CCStore.offRoster
        offAgentSampler = CCStore.offAgentSampler
        offBackdrop = CCStore.offBackdrop
        releaseMicWhenIdle = CCStore.releaseMicWhenIdle
        voiceProcessing = CCStore.voiceProcessing
        backdrop = CCStore.backdrop
        pushToTalkKey = CCStore.pushToTalkKey
        appearance = CCStore.appearance
        haptics = CCStore.haptics
        handwritten = CCStore.handwritten
    }

    /// 把内存里的勾选拉回跟磁盘一致。递归只会发生一次：
    /// 第二趟 `normalized == onlineRooms`，不再赋值。
    private func syncOnline() {
        let normalized = CCStore.onlineRooms
        if normalized != onlineRooms { onlineRooms = normalized }
    }

    /// 勾 / 取消勾一个房间。
    ///
    /// 当前说话的那个**不许取消** —— 直接忽略，而不是弹个提示。
    /// 想让它下线，先把话筒切给别人，那才是用户真正的意图。
    func toggleOnline(_ name: String) {
        CCStore.toggleOnline(name)
        syncOnline()
    }

    /// 拉到新名单之后更新本地缓存，顺带校一次当前选择。
    ///
    /// 名单本身由 `CCRoomDirectory` 持有并发布，这里只留一份逗号分隔的副本给冷启动垫底。
    /// 校准那一步不能省：上次选的 bot 可能已经从名单里去掉了，
    /// 不校的话选择器显示空白，要到点连接那一刻才拿到 400。
    func applyDirectory(names: [String]) {
        CCStore.roomsCSV = names.joined(separator: ",")
        let normalized = CCStore.room
        if normalized != room { room = normalized }
        // 勾选也要跟着校：名单里去掉的 bot，勾还留着的话界面会显示一个连不上的房间。
        syncOnline()
    }
}
