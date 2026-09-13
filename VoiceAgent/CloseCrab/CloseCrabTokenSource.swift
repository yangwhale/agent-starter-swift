import CryptoKit
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
    func fetch(_: TokenRequestOptions) async throws -> TokenSourceResponse {
        let room = CCStore.room
        guard !room.isEmpty else {
            throw CCTokenError("还没选房间 —— 在设置里填上房间列表")
        }
        guard var comps = URLComponents(string: CCStore.baseURL) else {
            throw CCTokenError("服务器地址填得不对：\(CCStore.baseURL)")
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/api/token"
        comps.queryItems = [URLQueryItem(name: "room", value: room)]
        guard let url = comps.url else {
            throw CCTokenError("拼不出 token 地址：\(CCStore.baseURL)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        req.timeoutInterval = 15
        for (k, v) in authHeaders(room: room) {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CCTokenError("token 服务没给出 HTTP 响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            // 把响应正文带出来。那个路由的失败信息是有内容的
            // （"room not allowed: xxx"、"ALLOWED_ROOMS is not defined"），
            // 吞掉它就只剩一个光秃秃的状态码，等于把排查成本原样丢给下一个人。
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CCTokenError("token 服务返回 \(http.statusCode)\(body.isEmpty ? "" : "：\(body)")")
        }

        let decoded = try JSONDecoder().decode(CamelCaseResponse.self, from: data)

        // 信令地址：设置里填了就以设置为准。
        // 服务端给的那个是**给浏览器用的** —— 和页面同源、一起躲在 IAP 后面，
        // 手机上没有那张登录 cookie，照着连必然在握手时被弹走。
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

    /// 没配密钥就不发这两个头 —— 服务端现在也还没验签，发不发都能连上。
    ///
    /// 签的是 `<房间>:<秒级时间戳>`，不是密钥本身：密钥不上网，
    /// 服务端按同样的串重算一遍比对，再看时间戳偏差（建议 ±300 秒）挡重放。
    /// 服务端那一半还没接（见 README「还差什么」），这边先按这个约定发着，
    /// 接的时候不用再改 app。
    private func authHeaders(room: String) -> [String: String] {
        let secret = CCStore.sharedSecret
        guard !secret.isEmpty else { return [:] }
        let ts = String(Int(Date().timeIntervalSince1970))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("\(room):\(ts)".utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        return [
            "X-CC-Ts": ts,
            "X-CC-Sig": mac.map { String(format: "%02x", $0) }.joined(),
        ]
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
