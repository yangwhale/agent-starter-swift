import CryptoKit
import Foundation

/// 跟自家后端说话的两件公共事：地址怎么拼、请求怎么签。
///
/// 抽出来是因为现在有两个调用方（要 token 的 `CloseCrabTokenSource`、
/// 要房间列表的 `CCRoomDirectory`），而签名格式一旦两边写歪一个字符，
/// 症状是 403「签名不匹配」—— 看不出是哪边错的。一份实现就没这个问题。
enum CCEndpoint {
    /// 在配置的根地址后面接一段路径。
    ///
    /// 会把根地址尾部的 `/` 吃掉：`https://x/native/` + `/api/token` 拼成
    /// `//api/token` 的话，Next.js 直接 404，而设置页里多打一个斜杠太常见了。
    static func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        let base = CCStore.baseURL
        guard var comps = URLComponents(string: base) else {
            throw CCTokenError("服务器地址填得不对：\(base)")
        }
        let trimmed = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = trimmed + path
        comps.queryItems = query.isEmpty ? nil : query
        guard let url = comps.url else {
            throw CCTokenError("拼不出请求地址：\(base)\(path)")
        }
        return url
    }

    /// 没配密钥就不发这两个头。
    ///
    /// 签的是 `<scope>:<秒级时间戳>`，不是密钥本身 —— 密钥不上网，服务端按同样的
    /// 串重算一遍比对。scope 对 `/api/token` 是房间名，对 `/api/rooms` 是字面量
    /// `rooms`：把它签进去，抓到的一次 `?room=bunny` 请求就不能改成
    /// `?room=jarvis` 重放。时间戳服务端只收 ±300 秒。
    static func signedHeaders(scope: String) -> [String: String] {
        let secret = CCStore.sharedSecret
        guard !secret.isEmpty else { return [:] }
        let ts = String(Int(Date().timeIntervalSince1970))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("\(scope):\(ts)".utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        return [
            "X-CC-Ts": ts,
            "X-CC-Sig": mac.map { String(format: "%02x", $0) }.joined(),
        ]
    }

    /// 非 2xx 时把响应正文一起抛出来。
    ///
    /// 后端的失败信息是有内容的（"room not allowed: xxx"、"缺少 X-CC-Ts / X-CC-Sig"、
    /// "时间戳超出 ±300 秒，检查设备时钟"），吞掉就只剩一个光秃秃的状态码 ——
    /// 等于把排查成本原样丢给下一个人。
    static func checkStatus(_ response: URLResponse, body: Data, what: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CCTokenError("\(what)没给出 HTTP 响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let text = String(data: body, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CCTokenError("\(what)返回 \(http.statusCode)\(text.isEmpty ? "" : "：\(text)")")
        }
    }
}
