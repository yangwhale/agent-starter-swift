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
    @Published var room: String { didSet { CCStore.room = room } }

    private init() {
        baseURL = CCStore.baseURL
        signalURL = CCStore.signalURL
        sharedSecret = CCStore.sharedSecret
        room = CCStore.room
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
    }
}
