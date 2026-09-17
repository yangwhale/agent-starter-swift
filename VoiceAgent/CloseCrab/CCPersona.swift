import Foundation
import SwiftUI

/// 数字人**现在用哪张脸** —— 取、换、缓存。
///
/// ## 这张图从哪来
///
/// 手机连不到数字人控制面（它在 VPC 内网，公网上没有入口，也不该有）。
/// 链路是 **手机 → 自家后端 `/api/avatar/persona/{room}`（HMAC 验签）→ 控制面**。
/// 后端持有控制面的 key，手机永远拿不到。
///
/// ## 为什么按版本缓存而不是按时间
///
/// 后端回的 `ETag` 是**图片内容的哈希**。同一张图重传版本号不变，
/// 所以不会因为一次无谓的上传就让全房间重新下一遍图。
/// 用时间戳缓存的话，换了脸却在有效期内的那几分钟里你看到的还是旧的 ——
/// 而你刚刚才换过，只会以为上传失败又传一遍。
@MainActor
final class CCPersona: ObservableObject {
    static let shared = CCPersona()

    /// 每个房间当前那张图。key 是房间名。
    @Published private(set) var images: [String: Image] = [:]
    /// 当前版本号（＝内容哈希）。用来判断要不要重新下。
    @Published private(set) var versions: [String: String] = [:]
    /// 正在上传的房间 —— 界面据此转圈并挡住重复点击。
    @Published private(set) var uploading: Set<String> = []
    /// 上一次失败的原因，按房间存。**要显示给用户**：
    /// 「点了没反应」是这类功能最常见的投诉，而原因后端都写清楚了。
    @Published private(set) var lastError: [String: String] = [:]

    private var inflight: Set<String> = []

    private init() {}

    // MARK: - 取

    /// 确保这个房间的图在手上。已经有同版本的就什么都不做。
    ///
    /// - Parameter force: 刚上传完用 `true` 跳过版本比对 —— 那一刻本地版本
    ///   还是旧的，不强制的话会认为「没变」而不刷新。
    func ensure(room: String, force: Bool = false) {
        guard !room.isEmpty, !inflight.contains(room) else { return }
        inflight.insert(room)
        Task { [weak self] in
            defer { Task { @MainActor in self?.inflight.remove(room) } }
            await self?.load(room: room, force: force)
        }
    }

    private func load(room: String, force: Bool) async {
        do {
            let url = try CCEndpoint.url(path: "/api/avatar/persona/\(room)/image")
            var req = URLRequest(url: url)
            for (k, v) in CCEndpoint.signedHeaders(scope: "persona:\(room)") {
                req.setValue(v, forHTTPHeaderField: k)
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }
            if http.statusCode == 404 {
                // 没设过 —— 这是正常状态，不是错误。清掉旧的，别留着上一张。
                images[room] = nil
                versions[room] = nil
                lastError[room] = nil
                return
            }
            guard http.statusCode == 200 else {
                lastError[room] = "取形象图失败（\(http.statusCode)）"
                return
            }
            let etag = (http.value(forHTTPHeaderField: "ETag") ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !force, !etag.isEmpty, versions[room] == etag { return }

            guard let img = CCPersona.decode(data) else {
                lastError[room] = "服务端给的不是能显示的图片"
                return
            }
            images[room] = img
            versions[room] = etag
            lastError[room] = nil
        } catch {
            lastError[room] = error.localizedDescription
        }
    }

    // MARK: - 换

    /// 传一张新的。成功后立刻重新取一遍（`force: true`）。
    func upload(room: String, data: Data, contentType: String, note: String = "") {
        guard !uploading.contains(room) else { return }
        uploading.insert(room)
        Task { [weak self] in
            await self?.put(room: room, data: data, contentType: contentType, note: note)
            await MainActor.run { self?.uploading.remove(room) }
        }
    }

    private func put(room: String, data: Data, contentType: String, note: String) async {
        do {
            let url = try CCEndpoint.url(
                path: "/api/avatar/persona/\(room)",
                query: note.isEmpty ? [] : [URLQueryItem(name: "note", value: note)])
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            for (k, v) in CCEndpoint.signedHeaders(scope: "persona:\(room)") {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.httpBody = data
            let (body, resp) = try await URLSession.shared.data(for: req)
            try CCEndpoint.checkStatus(resp, body: body, what: "上传形象图")
            lastError[room] = nil
            // 换完立刻刷。**不能等下次自然刷新** —— 用户刚按完，
            // 屏幕上还是旧图的话他会以为没成功。
            ensure(room: room, force: true)
        } catch {
            lastError[room] = error.localizedDescription
        }
    }

    // MARK: - 杂

    /// 图片数据 → SwiftUI Image。平台差异只有这一处，包在这儿省得到处 `#if`。
    static func decode(_ data: Data) -> Image? {
        #if canImport(UIKit)
            guard let ui = UIImage(data: data) else { return nil }
            return Image(uiImage: ui)
        #elseif canImport(AppKit)
            guard let ns = NSImage(data: data) else { return nil }
            return Image(nsImage: ns)
        #else
            return nil
        #endif
    }

    /// 按魔数认类型。**不看文件名** —— 相册导出的扩展名不一定对，
    /// 而服务端那边也是按内容判的，这里先对齐，省得传上去被 400 打回来。
    static func sniff(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 8, Array(b[0 ..< 8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return "image/png"
        }
        if b.count >= 12, Array(b[0 ..< 4]) == Array("RIFF".utf8),
           Array(b[8 ..< 12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }
}
