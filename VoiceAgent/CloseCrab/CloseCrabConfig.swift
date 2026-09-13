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

    /// 改完房间列表要顺手校一次当前选择：删掉了正在用的那个之后，
    /// 选择器会显示空白但内部还留着旧值，点连接才报「房间不允许」。
    @Published var roomsCSV: String {
        didSet {
            CCStore.roomsCSV = roomsCSV
            let normalized = CCStore.room
            if normalized != room { room = normalized }
        }
    }

    var rooms: [String] { CCStore.rooms }

    private init() {
        baseURL = CCStore.baseURL
        signalURL = CCStore.signalURL
        sharedSecret = CCStore.sharedSecret
        roomsCSV = CCStore.roomsCSV
        room = CCStore.room
    }
}
