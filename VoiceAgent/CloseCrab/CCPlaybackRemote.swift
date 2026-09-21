import Foundation
import LiveKit
import Observation

/// 遥控**服务端那个播放器** —— 跟飞书卡片上那五个按钮是同一个东西。
///
/// ## 这不是控制本地播放
///
/// bot 说话的音频是服务端合成好、通过 LiveKit 推下来的一条实时流。
/// 手机这边只是**听众**，没有可以暂停的本地缓冲。
/// 所以「暂停」必须是一次**回到服务端的调用**：让那边的播放器停止往外推帧。
///
/// ⇒ 顺带的好处：手机上按暂停，**飞书卡片上的进度条会跟着停** ——
/// 两边操作的本来就是同一个播放器实例，不是两套状态。
///
/// ## 服务端早就做好了，这边一直是空的
///
/// `closecrab/voice/livekit_out.py` 里的 `_register_playback_rpc()`
/// 把六个方法注册在 `<房间名>-speaker` 这个参与者上，注释原话是
/// 「让 app 能遥控」—— 当初就是按这个目标做的。
/// 2026-09-22 之前客户端一个调用都没有。
///
/// ## 为什么是 RPC 不是数据消息
///
/// 抄服务端注释里的理由：这几个都是**动作**，而且调用方要知道成没成 ——
/// 「已经播完了」之后按暂停应该返回失败，不是静默无事发生。
/// 数据消息是单向的，给不了回执。
@MainActor
@Observable
final class CCPlaybackRemote {
    /// 服务端此刻在不在播。**只有它为真时界面才该出现。**
    private(set) var isActive = false
    /// 已播秒数。
    private(set) var played: Double = 0
    /// 总秒数。
    ///
    /// ⚠️ **可以是 nil，而且必须当回事。** 服务端在音频还没生成完时
    /// 会如实传 null（它的注释写着「别编一个分母」）。
    /// 这里跟着传 nil，界面**不许**在这种时候画进度条 ——
    /// 画了就会显示成「快播完了」，而实际上它还在生成。
    private(set) var total: Double?
    /// 当前这段的 id。重播用得上，但一般不用自己传（不传就是重播当前段）。
    private(set) var fid = ""
    /// 最近一次调用失败的原因；成功时清空。**界面要显示它** ——
    /// 遥控失败如果是静默的，用户只会觉得「这按钮有时候不灵」。
    private(set) var lastError: String?

    /// 有没有找到那个 speaker 参与者。没有就说明服务端那一路没连进来，
    /// 按钮该是灰的 —— 而不是按下去等 15 秒超时。
    private(set) var reachable = false

    private let room: Room
    private let target: Participant.Identity
    private var poller: Task<Void, Never>?

    /// - Parameter roomName: 房间名 ＝ bot 名。服务端那个参与者的 identity
    ///   是 `<bot>-speaker`（`livekit_out.py:690`，`f"{bot_name}-speaker"`）。
    init(room: Room, roomName: String) {
        self.room = room
        target = Participant.Identity(from: "\(roomName)-speaker")
    }

    // MARK: - 五个按钮

    func pause() async { await call("pause") }
    func resume() async { await call("resume") }
    func stop() async { await call("stop") }

    /// 重播当前这一段。**不传 fid** —— 服务端会自己查当前段，
    /// 让客户端先查一次进度再重播是没必要的往返（它注释里专门写了这点）。
    func replay() async { await call("replay") }

    /// 前后拖。`delta` 是**比例**不是秒数，范围 -1…1，
    /// 超出范围服务端会直接回失败（不会静默截断）。
    func seek(_ delta: Double) async {
        await call("seek", payload: ["delta": delta])
    }

    // MARK: - 进度

    /// 拉一次进度。**失败时不清空已有状态** ——
    /// 一次网络抖动把进度条清零，看起来像播放中断了。
    func refresh() async {
        guard let json = await invoke("progress") else { return }
        isActive = json["active"] as? Bool ?? false
        played = json["played"] as? Double ?? 0
        // `total` 可能是 JSON null ⇒ `as? Double` 自然得到 nil，正是我们要的。
        total = json["total"] as? Double
        fid = json["fid"] as? String ?? ""
    }

    /// 开始每秒拉一次。**只在界面看得见时开** ——
    /// 常驻轮询是一条纯耗电的链路，而没人看的时候进度没有意义。
    func startPolling() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                // ⚠️ **`guard let self else { return }`，不是 `await self?.refresh()`。**
                //    后者在对象没了之后不报错也不停 —— 循环每秒空转一次，
                //    永远转下去。弱引用防的是「泄漏对象」，
                //    **它不防「泄漏循环」**，这两件事得分开处理。
                guard let self else { return }
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    // ⛔ 这里**不能写 `deinit { poller?.cancel() }`** —— `deinit` 是
    //    nonisolated 的，碰 `@MainActor` 的存储属性在 Swift 6 下过不去。
    //    循环的终止改由上面那个 `guard let self` 兜底：对象一没，下一轮就退。

    // MARK: - 底层

    /// 按一个按钮：调完**立刻刷一次进度**。
    ///
    /// 不等下一个轮询周期 —— 那要等最多 1 秒，而按钮按下去 1 秒没反应
    /// 的体感就是「没按到」，用户会再按一次。
    private func call(_ method: String, payload: [String: Any] = [:]) async {
        guard await invoke(method, payload: payload) != nil else { return }
        await refresh()
    }

    /// 返回解出来的 JSON；失败返回 nil 并把原因写进 `lastError`。
    private func invoke(_ method: String, payload: [String: Any] = [:]) async -> [String: Any]? {
        // 先看那个参与者在不在。不在就直接失败 ——
        // 否则 `performRpc` 会老老实实等满超时，界面卡 15 秒。
        guard room.remoteParticipants[target] != nil else {
            reachable = false
            lastError = "播放器没连进这个房间"
            return nil
        }
        reachable = true

        let body: String
        if payload.isEmpty {
            body = "{}"
        } else if let data = try? JSONSerialization.data(withJSONObject: payload),
                  let text = String(data: data, encoding: .utf8) {
            body = text
        } else {
            lastError = "参数编码失败"
            return nil
        }

        do {
            let reply = try await room.localParticipant.performRpc(
                destinationIdentity: target,
                method: "cc.playback.\(method)",
                payload: body,
                // 默认 15 秒太长。这几个都是本地动作，服务端不该想那么久；
                // 真超了也是出问题了，早点告诉用户比干等着强。
                responseTimeout: 5
            )
            guard let data = reply.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                lastError = "服务端回了看不懂的东西"
                return nil
            }
            // ⚠️ **`ok: false` 不是错误，是「这个动作现在做不了」** ——
            //    比如已经播完了还按暂停。服务端专门为此设计了回执，
            //    这里要如实反映，但不该当成故障刷红。
            if json["ok"] as? Bool == false {
                lastError = json["error"] as? String ?? "现在做不了这个操作"
            } else {
                lastError = nil
            }
            return json
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
