import Combine
import LiveKit
import SwiftUI

/// 麦克风策略：**进房默认闭麦**，说话靠按住不放。
///
/// ## 为什么需要这么一个东西，而不是改个参数
///
/// 直觉上「默认静音」应该是 `SessionOptions(preConnectAudio: false)` 一行的事。
/// **不是。** 扒了 SDK 源码（`Session.start()`）：
///
/// ```swift
/// if options.preConnectAudio {
///     … withPreConnectAudio { connect() }        // 连接前就开始采集
/// } else {
///     dispatchesAgent = try await connect()
///     try await room.localParticipant.setMicrophone(enabled: true)   // ← 无条件开麦
/// }
/// ```
///
/// 两条分支**都会开麦**，只是时机不同。所以 `preConnectAudio: false` 只解决了
/// 「连上之前别偷跑」，连上之后那一下还得有人按回去 —— 就是这个类。
///
/// ⚠️ 这正是那种「改了一处就以为好了」的坑：参数名写着 preConnect，
/// 让人以为它管的是「要不要开麦」，实际管的只是「什么时候开」。
///
/// ## 为什么默认闭麦
///
/// - bot 的声音从扬声器出来会被麦克风收回去，被当成「你说话了」。闭麦直接消掉这条。
/// - 多房间之后更要命：你在听 A 说话，嘴边的呼吸声被发给 B，B 就抢答了。
///
/// ## 手动开麦不会被它按回去
///
/// 只在**每次新连接建立的那一刻**强制闭一次。之后你点控制栏的麦克风按钮常开，
/// 它不管 —— 否则用户会觉得「这破按钮点了就弹回去」。
@MainActor
@Observable
final class CCMicPolicy {
    /// 按住说话期间为 true。用来给界面上那片区域画高亮，也用来挡住重复触发。
    ///
    /// **属性级追踪**：读它的那条说话栏会自己更新，别的地方不受影响。
    /// 原来是 `@Published` —— 对象级通知，这个类里随便改点什么都要惊动订阅者。
    private(set) var isHolding = false

    private let session: Session
    private var cancellable: AnyCancellable?
    /// 上一次看到的连接状态。**只在 false→true 的那一下动手** ——
    /// 每次状态变化都闭麦的话，手动开麦会被后续任何一次无关的状态刷新打回去。
    private var wasConnected = false

    init(session: Session) {
        self.session = session
        wasConnected = session.isConnected
        // `receive(on:)` 只保证在主**线程**，编译器并不知道那就是 MainActor ——
        // Swift 6 严格并发下直接调 `connectionChanged()` 会报跨 actor 调用。
        // 包一层 `Task { @MainActor in }` 把隔离说清楚。
        //
        // 📌 **这是全 app 最后一个没做合并的 `session.objectWillChange` 订阅。**
        //    `CCRooms` 那条有 80 ms 合并窗口，这条没有 —— 连接建立那几秒上游
        //    能到 310 次/秒，这里就会起 310 个 Task，而其中只有一个会真干活。
        //    **它到底占多少电没量过**，所以先只记下来，不凭感觉改：
        //    真要改的话，难点是 sink 闭包里读不到 MainActor 上的状态，
        //    没法在进 Task 之前就把无关通知挡掉。
        cancellable = session.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.connectionChanged() }
            }
    }

    private func connectionChanged() {
        let now = session.isConnected
        defer { wasConnected = now }
        guard now, !wasConnected else { return }
        // 刚连上：把 SDK 替我们开的那一下按回去。
        cancelTail()
        isHolding = false
        Task { await setMic(false) }
    }

    /// `session.start()` 返回之后必须再闭一次 —— **这一次才是真正生效的那次。**
    ///
    /// 上面那个监听靠不住，原因在 SDK 的 `isConnected`：
    ///
    /// ```swift
    /// public var isConnected: Bool {
    ///     switch connectionState {
    ///     case .connecting, .connected, .reconnecting: true   // ← .connecting 就算连上了
    /// ```
    ///
    /// 而 `start()` 的顺序是「先把状态置成 .connecting，再去连，连上了才开麦」：
    ///
    /// ```swift
    /// connectionState = .connecting                                  // (1) isConnected 变 true
    /// dispatchesAgent = try await connect()                          // (2) 网络往返
    /// try await room.localParticipant.setMicrophone(enabled: true)   // (3) 开麦
    /// ```
    ///
    /// 监听在 (1) 就被叫醒，那时 room 还没连上，闭麦是空操作；等它把 `wasConnected`
    /// 置成 true，(3) 的开麦就再也没人管了 —— 表现就是「进去麦是开的」。
    ///
    /// 所以闭麦必须发生在 `start()` 返回之后，那是唯一能保证晚于 (3) 的时机。
    func enforceMutedAfterConnect() async {
        guard session.isConnected else { return }
        cancelTail()
        isHolding = false
        await setMic(false)
    }

    // MARK: - 按住说话

    /// 松手之后麦克风**还要多开这么久**。
    ///
    /// ## 为什么非要留这条尾巴
    ///
    /// 09-15 20:20 实测的服务端日志：
    ///
    /// ```
    /// 20:20:04 解除静音
    /// 20:20:05 SFU 听见有人在出声
    /// 20:20:06 静音了            ← 说完一秒就切了
    /// ```
    ///
    /// 三次按住全是这个形状，而助手**一次都没回答**。
    ///
    /// 原因是 Gemini Live 的轮次判断靠的是**音频流里的那段静音** ——
    /// 「他不说了，该我了」。一说完就把轨切掉，它收到的不是静音，
    /// 是音频**直接没了**，那一轮永远等不到收尾，于是它一直在听。
    ///
    /// 留 900ms 的尾巴就是把这段静音补上。代价是松手之后近一秒内的环境音
    /// 也会进去 —— 可接受，因为那正是模型用来判断「说完了」的素材。
    private static let releaseTailMs = 900

    /// 松手之后那条还没落地的尾巴。再次按下要能把它撤回来。
    private var releaseTask: Task<Void, Never>?

    /// 按住中间那片空白 → 临时开麦。
    ///
    /// **仅在当前是闭麦状态时有效**（Chris 09-14 定）：已经手动常开了就什么都不做，
    /// 否则松手会把用户手动打开的麦克风关掉 —— 那是「我明明开着的怎么没了」。
    func beginHold(isMicrophoneEnabled: Bool) {
        // 尾巴还没落地就又按下来了（连着说两句）：麦本来就还开着，
        // 撤掉那个关麦任务、直接接上就行。
        //
        // **这一支不能省。** 走下面那条的话，`isMicrophoneEnabled` 此刻是 true，
        // guard 会直接 return，`isHolding` 停在 false —— 然后松手时 `endHold`
        // 的 guard 也过不去，麦克风就**再也关不上了**。
        if releaseTask != nil {
            releaseTask?.cancel()
            releaseTask = nil
            isHolding = true
            return
        }
        guard !isHolding, !isMicrophoneEnabled, session.isConnected else { return }
        isHolding = true
        Task { await setMic(true) }
    }

    /// 松手 → 等一小段再闭麦，给模型留出判断「说完了」的静音。
    func endHold() {
        guard isHolding else { return }
        // 界面立刻回弹，不等尾巴 —— 按钮黏在按下态会让人以为没松开。
        // 真正的闭麦晚 900ms，这个不一致是**故意的**：
        // 界面反映的是「手的意图」，麦克风反映的是「模型还需要什么」。
        isHolding = false
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.releaseTailMs))
            guard !Task.isCancelled else { return }
            await self?.setMic(false)
            self?.releaseTask = nil
        }
    }

    /// 把还没落地的尾巴撤掉并立刻闭麦。切房间、断线重连这种场合用 ——
    /// 那时候留着尾巴等于把麦克风交给下一个房间。
    private func cancelTail() {
        releaseTask?.cancel()
        releaseTask = nil
    }

    // MARK: -

    /// `LocalMedia.isMicrophoneEnabled` 是 `private(set)`，只有 `toggleMicrophone()`
    /// 是公开的 —— 而 toggle 是相对操作，在「不确定当前状态」的时候用它等于掷硬币。
    /// 所以直接对 `LocalParticipant` 设绝对值。
    private func setMic(_ enabled: Bool) async {
        do {
            try await session.room.localParticipant.setMicrophone(enabled: enabled)
        } catch {
            // 开麦失败要让人知道（说了半天没人听见）；关麦失败只记一笔，
            // 因为那多半是因为本来就没开。
            if enabled { print("[CCMicPolicy] 开麦失败: \(error)") }
        }
    }
}
