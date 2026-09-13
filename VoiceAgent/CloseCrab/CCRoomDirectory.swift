import Foundation
import SwiftUI

/// 一个房间（＝一个 bot）在目录里的样子。
///
/// `online` / `ready` 是**三态**：`nil` 表示服务端没查到 SFU，不是「不在线」。
/// 把「不知道」画成「离线」会让人以为 bot 挂了，实际只是管理接口抽风 ——
/// 这种误导比不显示状态更糟。
struct CCRoom: Identifiable, Equatable, Decodable {
    let name: String
    let online: Bool?
    let ready: Bool?
    let participants: Int?

    var id: String { name }

    init(name: String, online: Bool? = nil, ready: Bool? = nil, participants: Int? = nil) {
        self.name = name
        self.online = online
        self.ready = ready
        self.participants = participants
    }
}

/// 房间列表从服务端来，不在每台设备上手写。
///
/// 以前列表是设置页里一串逗号分隔的文本 —— 加一个 bot 就得把六台设备挨个改一遍，
/// 而且改错了要到点连接那一刻才报 400。现在问 `/api/rooms`，那边跟 `/api/token`
/// 共用同一份 `ALLOWED_ROOMS`，所以「列得出来」和「换得到 token」不可能对不上。
///
/// 本地仍然留一份上次拿到的名单（存在 `CCStore.roomsCSV`），只当缓存用：
/// 冷启动、飞行模式下界面不至于空着。**它不是第二份真理** —— 每次拉取成功都整份覆盖。
@MainActor
final class CCRoomDirectory: ObservableObject {
    static let shared = CCRoomDirectory()

    @Published private(set) var rooms: [CCRoom]
    @Published private(set) var isRefreshing = false
    /// 上次拉取的错误。留着显示给人看，而不是默默退回缓存 ——
    /// 「列表是旧的」和「列表是新的」长得一模一样，不说没人知道。
    @Published private(set) var lastError: String?

    private init() {
        rooms = CCStore.rooms.map { CCRoom(name: $0) }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let url = try CCEndpoint.url(path: "/api/rooms")
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.cachePolicy = .reloadIgnoringLocalCacheData
            for (k, v) in CCEndpoint.signedHeaders(scope: "rooms") {
                req.setValue(v, forHTTPHeaderField: k)
            }

            let (data, response) = try await URLSession.shared.data(for: req)
            try CCEndpoint.checkStatus(response, body: data, what: "房间列表")

            let decoded = try JSONDecoder().decode(RoomsResponse.self, from: data)
            guard !decoded.rooms.isEmpty else {
                // 空名单多半是服务端 ALLOWED_ROOMS 没配好。照单全收会把界面清空，
                // 用户看到的是「一个房间都没有」，而不是「配置出问题了」。
                throw CCTokenError("服务端回了一份空名单，检查前端的 ALLOWED_ROOMS")
            }

            rooms = decoded.rooms
            lastError = nil

            // 缓存整份覆盖，并顺手校一次当前选择：上次选的 bot 可能已经下架了，
            // 不校的话选择器显示空白、点连接才报「房间不允许」。
            CloseCrabConfig.shared.applyDirectory(names: decoded.rooms.map(\.name))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private struct RoomsResponse: Decodable {
        let rooms: [CCRoom]
    }
}
