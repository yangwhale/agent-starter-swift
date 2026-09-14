import Foundation
import LiveKit

/// 向 CloseCrab 自己的前端要一张房间 token。
///
/// 没有复用 SDK 的 `EndpointTokenSource`，有两个实打实的理由：
///
/// 1. **房间名走查询串**。我们的 `/api/token` 是 `?room=<bot>`，不是 body 里的
///    `room_name` —— 因为服务端要拿它查白名单，而白名单这层校验必须在签 JWT
///    之前发生。`EndpointTokenSource` 只会把参数塞进 body。
/// 2. **返回的字段是小驼峰**。上游 starter 约定 `server_url` / `participant_token`
///    下划线风格，我们那个路由是 Next.js 官方模板改的，一直是 `serverUrl` /
///    `participantToken`。改服务端会连带把网页版一起弄坏，所以在这边解。
///
/// 顺带把 body 发成空对象 `{}`：那个路由会 `await req.json()`，没有 body 直接抛；
/// 而 SDK 默认塞的 `room_config` 会被它拿去 `RoomConfiguration.fromJson`，
/// 多一个能失败的环节，我们又用不上显式派发（agent 是常驻的，房间早就有人在岗）。
struct CloseCrabTokenSource: TokenSourceConfigurable {
    /// 绑定到哪个房间。
    ///
    /// - 非 nil：这条连接**固定**连这个房间。多房间层用这个 —— 否则 N 条连接
    ///   会全部跑去连「当前房间」那一个。
    /// - nil：现读全局当前房间（单房间时代的行为，留着兼容）。
    var room: String?

    init(room: String? = nil) { self.room = room }

    func fetch(_: TokenRequestOptions) async throws -> TokenSourceResponse {
        // nil 时每次现读，不在初始化时捕获 —— 单房间那条路靠的就是这一句：
        // 抽屉里改完选择、重连一次，新的 fetch 自然拿到新房间名。
        let room = self.room ?? CCStore.room
        guard !room.isEmpty else {
            throw CCTokenError("还没选房间 —— 打开房间列表挑一个")
        }

        let url = try CCEndpoint.url(path: "/api/token", query: [URLQueryItem(name: "room", value: room)])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        req.timeoutInterval = 15
        for (k, v) in CCEndpoint.signedHeaders(scope: room) {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        try CCEndpoint.checkStatus(response, body: data, what: "token 服务")

        let decoded = try JSONDecoder().decode(CamelCaseResponse.self, from: data)

        // 信令地址：设置里填了就以设置为准，留空听服务端的。
        //
        // 服务端现在会按入口给不同的地址 —— 从 `/native/*` 进来的拿到
        // `wss://.../native/lk`（不在 IAP 后面），浏览器拿到 `wss://.../lk`。
        // 所以正常情况下这个覆盖项应该是空的，它只是换域名、加代理时的逃生口。
        let serverURL: URL
        if let override = URL(string: CCStore.signalURL), !CCStore.signalURL.isEmpty {
            serverURL = override
        } else if let fromServer = URL(string: decoded.serverUrl) {
            serverURL = fromServer
        } else {
            throw CCTokenError("服务端给的 serverUrl 解析不了：\(decoded.serverUrl)")
        }

        return TokenSourceResponse(
            serverURL: serverURL,
            participantToken: decoded.participantToken,
            participantName: decoded.participantName,
            roomName: decoded.roomName
        )
    }

    private struct CamelCaseResponse: Decodable {
        let serverUrl: String
        let roomName: String?
        let participantName: String?
        let participantToken: String
    }
}

struct CCTokenError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
