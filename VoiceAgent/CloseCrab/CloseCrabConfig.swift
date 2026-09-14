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
    @Published var onlineRooms: [String] { didSet { CCStore.onlineRooms = onlineRooms; syncOnline() } }

    /// 麦克风语音处理的实现。**全局一份**，每个房间的 `AudioOptions` 各自订阅它
    /// 往自己那条麦克风轨上应用（见 `AudioOptions.init`）。
    @Published var voiceProcessing: VoiceProcessingMode { didSet { CCStore.voiceProcessing = voiceProcessing } }

    private init() {
        baseURL = CCStore.baseURL
        signalURL = CCStore.signalURL
        sharedSecret = CCStore.sharedSecret
        room = CCStore.room
        onlineRooms = CCStore.onlineRooms
        voiceProcessing = CCStore.voiceProcessing
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
