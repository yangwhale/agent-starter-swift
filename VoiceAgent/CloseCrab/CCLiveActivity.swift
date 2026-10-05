#if os(iOS) && canImport(ActivityKit)

    // ## `Activity` 对象怎么拿 —— 这一条是编译期承重的
    //
    // `Activity` 在文档里只声明了 `Identifiable`，没有 `Sendable`；它的 `update` / `end`
    // 是在通用执行器上跑的 async 方法。工程是 Swift 6 ＋ 默认 MainActor，所以：
    //
    // - **长期存一个 `Activity` 在本类属性里、再 `await a.update(...)`** ⇒
    //   `sending 'self.activity' risks causing data races`
    // - **用本类（MainActor）的实例方法现查一个出来再 await** ⇒ 同样报错 ——
    //   isolated 方法的返回值被算进 MainActor 的区域
    // - **用 `nonisolated static` 方法现查**（参数只有 String）⇒ 返回值不属于任何隔离域，
    //   送出去合法 ✅
    //
    // 三条都是在 docker 里用一个仿 SDK 形状的最小例子（非 Sendable 类 ＋ `@concurrent` 的
    // async 方法）编出来的，不是推断。所以下面**只存 id**，每次用时走 `Self.find(_:)` 现取。
    //
    // `@preconcurrency` 是第二道保险：万一真 SDK 的标注跟最小例子不一样，它把这类
    // Sendable 诊断降级。tommy 编过之后可以试着去掉它，看是否还干净。
    @preconcurrency import ActivityKit
    import Foundation
    import Observation
    import UIKit

    /// 锁屏 / 灵动岛实时活动的 app 这一半：**开卡、推更新、结束、换卡、接按钮**。
    ///
    /// 判定全在 `CCLiveActivityPolicy`（纯 Foundation，离线测过）。这里只做三件事：
    /// 1. 从房间层读信号（`CCRooms` / 当前槽位 / `CCBotStatus` / `CCPlaybackRemote` / 皮肤）
    /// 2. 问 Policy 该干什么
    /// 3. 调 ActivityKit
    ///
    /// ## 什么时候算「变了」
    ///
    /// 用 `withObservationTracking` 订阅上面那些 `@Observable` 属性 —— 跟界面同一套
    /// 属性级追踪，**不轮询**。bot 干活时状态快照每 0.5 秒来一份，每份都会触发一次
    /// 重算；但卡片内容（心情、状态行、计时起点……）多半没变，Policy 判 `skip`，
    /// 不会真的推到系统那边去。
    ///
    /// 两类变化**不是**属性变化，得自己定闹钟：「刚干完」3 秒 / 「在说话」1.5 秒宽限到点、
    /// 节流窗口到点、10 分钟续期、7.5 小时换卡。全部合并成**一个**闹钟，取最早的那个。
    ///
    /// ## 后台
    ///
    /// 连着的时候 app 靠后台音频活着，这里的闹钟照常走。app 被杀 / 挂起的话就没人推了，
    /// 卡片 15 分钟后过期，扩展那边画成「已断开」—— v1 不做苹果推送（方案页定的）。
    ///
    /// ⚠️ **app 在后台时开不了新卡**（系统规定一般要在前台开）。所以 7.5 小时换卡如果
    /// 恰好落在后台，会失败；失败后 5 分钟再试一次，回到前台时立刻再试。
    /// 一直在后台的话，系统 8 小时时把旧卡收走，下次回前台时再开一张新的。
    @MainActor
    final class CCLiveActivity {
        static let shared = CCLiveActivity()
        private init() {}

        private weak var rooms: CCRooms?

        /// 手上那张卡的 id。**只存 id 不存对象**，理由见文件头（存对象编不过）。
        private var activityID: String?
        private var cardStartedAt: Date?
        private var lastPushed: CCLiveActivityState?
        private var lastPushAt: Date?

        /// 这一轮连接里用户在锁屏上划掉过卡片 ⇒ 不再开（直到下次按「开始」）。
        private var dismissedByUser = false
        /// 上一次看到的 `wantConnected`，用来抓「从假变真」那一下（新一轮连接）。
        private var lastWantConnected = false
        /// 最近一次开卡失败的时刻（后台开不了卡）。
        private var lastStartFailure: Date?

        /// 进入当前心情的时刻（计时起点在「没在跑一轮」时用它）。按房间记，切房间就重来。
        private var moodMemo: (room: String, mood: CCFaceMood, since: Date)?
        /// 上一次的计时起点（吃掉服务端 `sec` 的抖动，见 `CCLiveActivityPolicy.timerTolerance`）。
        private var timerMemo: (room: String, start: Date)?

        /// 观察登记着没有。**同一时刻只能有一份登记** —— `sync()` 还会被闹钟、回前台调到，
        /// 每次都登记的话，一次属性变化会回调好几次，回调里又登记，越滚越多。
        private var armed = false
        private var wake: (at: Date, task: Task<Void, Never>)?
        private var foregroundObserver: (any NSObjectProtocol)?

        // MARK: - 接线

        /// 接上房间层。**只调一次**（`VoiceAgentApp.init`）。
        func attach(rooms: CCRooms) {
            self.rooms = rooms

            // 卡片上的按钮在 app 进程里落到这儿（为什么是 app 进程，见 CCLiveActivityAttributes.swift 文件头）。
            CCLiveActivityBridge.handler = { [weak self] action, room in
                await self?.perform(action, room: room)
            }

            // 上一个进程留下的卡（app 被杀、崩溃）：此刻一个房间都没连，统统收掉 ——
            // 不收的话锁屏上会挂着一张永远不再更新的旧卡，跟新开的那张并排。
            Task {
                for a in Activity<CCLiveActivityAttributes>.activities {
                    await a.end(nil, dismissalPolicy: .immediate)
                }
            }

            // 回前台：开卡失败的退避清零（前台一定开得了），顺便重查一次系统开关 ——
            // 用户刚从「设置」里把实时活动打开回来，就是这条路。
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.lastStartFailure = nil
                    self?.sync()
                }
            }

            sync()
        }

        // MARK: - 主循环

        /// 卡片该是什么样 —— 一次读全部信号。
        private struct Inputs {
            var want: Bool
            var room: String
            var mood: CCFaceMood = .asleep
            var skin: CCFaceSkin?
            var presence: CCPresenceDot = .off
            var snapHeadline: String?
            var on = false
            var sec: Double = 0
            var subs = 0
            var isActive = false
            var isPaused = false
            var canReplay = false
            var peers: [(name: String, dot: CCPresenceDot)] = []
            var finishedAt: Date?
            var speechEndedAt: Date?
        }

        /// ⚠️ **无条件把要用的属性全读一遍**，不要写成「没连上就不读 bot 状态」——
        /// 观察登记的是**这次实际读到的**属性；条件读的话，那个条件翻转时没人通知我们。
        private func readInputs(now: Date) -> Inputs {
            guard let rooms else { return Inputs(want: false, room: "") }
            let peers = rooms.slots.map { (name: $0.name, dot: rooms.presence(for: $0)) }
            guard let slot = rooms.active else {
                return Inputs(want: rooms.wantConnected, room: "", peers: peers)
            }
            let presence = rooms.presence(for: slot)
            let snap = slot.botStatus.snap
            let mood = CCFaceMood.derive(
                presence: presence,
                botPresent: slot.botPresent,
                wait: snap?.wait ?? "",
                on: snap?.on ?? false,
                holding: slot.micPolicy.isHolding,
                speaking: slot.isSpeaking,
                muted: slot.isMuted,
                finishedAt: slot.botStatus.finishedAt,
                speechEndedAt: slot.speechEndedAt,
                now: now
            )
            return Inputs(
                want: rooms.wantConnected,
                room: slot.name,
                mood: mood,
                skin: CCRoomIcons.shared.faceSkin(for: slot.name),
                presence: presence,
                snapHeadline: snap?.headline,
                on: snap?.on ?? false,
                sec: snap?.sec ?? 0,
                subs: snap?.subs.run ?? 0,
                isActive: slot.playback.isActive,
                isPaused: slot.playback.isPaused,
                canReplay: slot.playback.canReplay,
                peers: peers,
                finishedAt: slot.botStatus.finishedAt,
                speechEndedAt: slot.speechEndedAt
            )
        }

        private func sync() {
            let now = Date()
            let inputs: Inputs
            if armed {
                inputs = readInputs(now: now)
            } else {
                armed = true
                inputs = withObservationTracking {
                    readInputs(now: now)
                } onChange: { [weak self] in
                    // 这个回调在「即将改变」时、在任意线程上来：跳回主线程、等值落定再算。
                    Task { @MainActor in
                        self?.armed = false
                        self?.sync()
                    }
                }
            }
            apply(inputs, now: now)
        }

        private func apply(_ i: Inputs, now: Date) {
            // 新一轮连接（按了「开始」）：上一轮划掉卡片的记录作废。
            if i.want && !lastWantConnected {
                dismissedByUser = false
                lastStartFailure = nil
            }
            lastWantConnected = i.want

            let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
            noteIfCardGone(now: now, enabled: enabled)

            let state = makeState(i, now: now)
            let life = CCLiveActivityPolicy.lifecycle(
                enabled: enabled,
                wantConnected: i.want, room: i.room,
                hasCard: activityID != nil, cardStartedAt: cardStartedAt,
                dismissedByUser: dismissedByUser, now: now)

            var wakeAt: [Date] = []
            switch life {
            case .none:
                break
            case .end:
                endCard()
            case .start:
                if CCLiveActivityPolicy.shouldRetryStart(lastFailure: lastStartFailure, now: now) {
                    startCard(state, now: now)
                }
            case .rollover:
                if CCLiveActivityPolicy.shouldRetryStart(lastFailure: lastStartFailure, now: now) {
                    let old = activityID
                    if startCard(state, now: now) { endCard(id: old) }
                }
                // 没换成（后台）：旧卡照常更新，别因为换卡失败就冻住。
                if activityID != nil { push(state, now: now, wakeAt: &wakeAt) }
            case .keep:
                push(state, now: now, wakeAt: &wakeAt)
            }

            // 自己定的闹钟：时间相关的心情到点、续期、换卡、开卡失败后的重试。
            if activityID != nil {
                if let t = CCLiveActivityPolicy.nextRecheck(
                    now: now, finishedAt: i.finishedAt, speechEndedAt: i.speechEndedAt) {
                    wakeAt.append(t)
                }
                if let at = lastPushAt { wakeAt.append(at.addingTimeInterval(CCLiveActivityPolicy.keepAliveAfter)) }
                if let s = cardStartedAt { wakeAt.append(s.addingTimeInterval(CCLiveActivityPolicy.rolloverAfter)) }
            }
            if let f = lastStartFailure, life == .start || life == .rollover {
                wakeAt.append(f.addingTimeInterval(CCLiveActivityPolicy.startRetry))
            }
            // 只要将来的：换卡失败时「开卡满 7.5 小时」那个时刻已经过去了，
            // 留着它会让闹钟每 50 毫秒响一次（重试节奏由 startRetry 那个时刻管）。
            scheduleWake(wakeAt.filter { $0 > now }.min(), now: now)
        }

        private func makeState(_ i: Inputs, now: Date) -> CCLiveActivityState {
            if moodMemo?.room != i.room || moodMemo?.mood != i.mood {
                moodMemo = (i.room, i.mood, now)
            }
            // 断线时 `on` 是残值（跟脸、状态行同一条规矩），不拿它算「这一轮跑了多久」。
            let live = i.mood != .asleep && i.mood != .searching
            let start = CCLiveActivityPolicy.timerStart(
                on: live && i.on, sec: i.sec, now: now,
                previous: timerMemo?.room == i.room ? timerMemo?.start : nil,
                moodSince: moodMemo?.since ?? now)
            timerMemo = (i.room, start)
            return CCLiveActivityPolicy.makeState(
                room: i.room, mood: i.mood, skin: i.skin, presence: i.presence,
                snapHeadline: i.snapHeadline, runningSubtasks: i.subs, timerStart: start,
                isActive: i.isActive, isPaused: i.isPaused, canReplay: i.canReplay,
                peers: i.peers)
        }

        // MARK: - ActivityKit

        /// 现取一份手上那张卡。**必须是 `nonisolated static`**，理由见文件头那节。
        nonisolated private static func find(_ id: String?) -> Activity<CCLiveActivityAttributes>? {
            guard let id else { return nil }
            return Activity<CCLiveActivityAttributes>.activities.first { $0.id == id }
        }

        /// 手上那张卡还在不在。不在了（用户划掉 / 系统收走）就放手；
        /// 算不算用户划掉的，判据在 `CCLiveActivityPolicy.goneMeansUserDismissed`。
        private func noteIfCardGone(now: Date, enabled: Bool) {
            guard let id = activityID else { return }
            let age = cardStartedAt.map { now.timeIntervalSince($0) } ?? 0
            // **只认「明确结束了」**：`.ended` / `.dismissed`，或者开了好几秒还查不到。
            // 别写成「不是 .active 就算没了」—— 刚开的卡、过期的卡、将来系统新加的状态
            // 都会被误判成「用户划掉」，而那个判定会让这一轮再也不开卡。
            if let st = Self.find(id)?.activityState {
                guard st == .ended || st == .dismissed else { return }
            } else if age < 5 {
                return
            }
            if CCLiveActivityPolicy.goneMeansUserDismissed(age: age, enabled: enabled) { dismissedByUser = true }
            print("[CCLiveActivity] 卡片没了（已开 \(Int(age)) 秒）→ \(dismissedByUser ? "当成用户划掉" : "系统到点收走")")
            forget()
        }

        @discardableResult
        private func startCard(_ state: CCLiveActivityState, now: Date) -> Bool {
            do {
                let a = try Activity<CCLiveActivityAttributes>.request(
                    attributes: CCLiveActivityAttributes(),
                    content: ActivityContent(state: state, staleDate: CCLiveActivityPolicy.staleDate(now: now)),
                    pushType: nil)
                activityID = a.id
                cardStartedAt = now
                lastPushed = state
                lastPushAt = now
                lastStartFailure = nil
                print("[CCLiveActivity] 开卡 \(state.room)")
                return true
            } catch {
                lastStartFailure = now
                print("⚠️ [CCLiveActivity] 开卡失败（后台时开不了是正常的）：\(error)")
                return false
            }
        }

        private func push(_ state: CCLiveActivityState, now: Date, wakeAt: inout [Date]) {
            switch CCLiveActivityPolicy.push(next: state, last: lastPushed, lastPushAt: lastPushAt, now: now) {
            case .skip:
                return
            case let .wait(dt):
                wakeAt.append(now.addingTimeInterval(dt))
                return
            case .now:
                break
            }
            // 先记账再 await：推的途中再来一份，节流要按这一次算。
            lastPushed = state
            lastPushAt = now
            let id = activityID
            let content = ActivityContent(state: state, staleDate: CCLiveActivityPolicy.staleDate(now: now))
            Task {
                guard let a = Self.find(id) else { return }
                await a.update(content)
            }
        }

        private func endCard(id: String? = nil) {
            let target = id ?? activityID
            if id == nil || id == activityID { forget() }
            guard let target else { return }
            print("[CCLiveActivity] 结束卡片")
            Task {
                guard let a = Self.find(target) else { return }
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }

        private func forget() {
            activityID = nil
            cardStartedAt = nil
            lastPushed = nil
            lastPushAt = nil
        }

        // MARK: - 闹钟

        /// 只留一个闹钟，取最早的。已经有一个更早（或同时）的就不动。
        private func scheduleWake(_ at: Date?, now: Date) {
            guard let at else { return }
            if let w = wake, w.at <= at, w.at > now { return }
            wake?.task.cancel()
            let delay = max(0.05, at.timeIntervalSince(now))
            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.wake = nil
                self.sync()
            }
            wake = (at, task)
        }

        // MARK: - 按钮

        private func perform(_ action: CCLiveActivityAction, room: String) async {
            guard let slot = rooms?.slots.first(where: { $0.name == room }) else {
                print("[CCLiveActivity] 按钮 \(action.rawValue)：房间 \(room) 不在（app 可能刚被系统拉起，还没连）")
                return
            }
            switch action {
            case .toggle:
                let r = await slot.playback.smartToggle()
                print("[CCLiveActivity] 按钮 toggle \(room) [\(r.before)] → \(r.action)：\(slot.playback.lastError ?? "ok")")
            case .replay:
                await slot.playback.replay()
                print("[CCLiveActivity] 按钮 replay \(room) → \(slot.playback.lastError ?? "ok")")
            }
        }
    }

#endif
