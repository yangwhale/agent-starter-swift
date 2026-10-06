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
    import LiveKit
    import Observation
    import UIKit

    /// 实时活动的事件流（带毫秒时间戳），诊断页看。
    ///
    /// Chris 2026-10-06：「点了暂停以后卡片就一直卡在那，推选项、播下一段都不变 ——
    /// app 没挂起，声音照样从 app 出来。」卡片不更新可能卡在四个地方：
    /// 没察觉到变化 / Policy 判了 skip 或 wait / update 调了但系统没收 / 卡片已被换掉。
    /// **没有逐步记录就只能猜**（我第一次就猜成了「app 被挂起」，猜错了）。
    /// 这里把每一步记下来，配合 `update` 之后回读系统里那份内容，一次复现就能定位。
    @MainActor
    @Observable
    final class CCLiveActivityLog {
        static let shared = CCLiveActivityLog()
        private(set) var events: [String] = []
        private static let stamp: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()

        func log(_ text: String) {
            events.append("\(Self.stamp.string(from: Date())) \(text)")
            if events.count > 24 { events.removeFirst(events.count - 24) }
            print("[CCLiveActivity] \(text)")
        }
    }

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
        /// 上一次算出来的播放进度（`CCLiveActivityPolicy.playMark` 靠它判断「能不能沿用」）。按房间记。
        private var playMemo: (room: String, mark: CCLiveActivityPolicy.PlayMark)?

        /// 上一次锁屏提醒的是哪句（60 秒内同一句不再提醒，见 `CCLiveActivityPolicy.shouldAlert`）。
        private var lastAlert: CCLiveActivityPolicy.AlertMark?
        /// 判定该提醒、但还没推出去的那次（节流窗口没到）。下一次真正推的时候带上提醒。
        /// 推出去、或卡片内容已经跟推过的一样（没东西可推了）就清掉 —— 不然一个过期的提醒
        /// 会挂在 10 分钟后那次续期上响出来。
        private var pendingAlert: (title: String, body: String)?

        /// 替卡片挂着号的那个播放器（`CCPlaybackRemote.acquirePolling`）。
        ///
        /// 锁屏时 `CCPlaybackBar` 被渲染闸门退了号，没有这一份的话进度就不再更新 ——
        /// 而实时活动正是锁屏时看的。**有卡就挂、卡没了就退、换房间就换一个挂。**
        /// `weak`：房间被删掉时别让这里把一个连着死房间的播放器续命（它的轮询循环
        /// 靠「对象没了就退出」收尾，见 `acquirePolling`）。
        private weak var pollingRemote: CCPlaybackRemote?
        private static let pollOwner = "live-activity"

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
            CCLiveActivityBridge.replyHandler = { [weak self] room, text in
                await self?.quickReply(room: room, text: text)
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
            /// 房间设的 emoji（没设 nil）。卡片头像用它（`CCLiveActivityPolicy.avatar`）。
            var emoji: String?
            var presence: CCPresenceDot = .off
            var snapHeadline: String?
            var wait = ""
            var opts: [String] = []
            var optl: [String] = []
            /// 刚快捷回复过的那句和时刻（`CCQuickReplySender`，主界面点的也算 —— 一个槽位一份）。
            var repliedText: String?
            var repliedAt: Date?
            var on = false
            var sec: Double = 0
            var subs = 0
            var isActive = false
            var isPaused = false
            var canReplay = false
            var played: Double = 0
            var total: Double?
            var fid = ""
            var playback: CCPlaybackRemote?
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
                emoji: CCRoomIcons.shared.hasCustomIcon(slot.name) ? CCRoomIcons.shared.icon(for: slot.name) : nil,
                presence: presence,
                snapHeadline: snap?.headline,
                wait: snap?.wait ?? "",
                opts: snap?.opts ?? [],
                optl: snap?.optl ?? [],
                repliedText: slot.quickReply.repliedText,
                repliedAt: slot.quickReply.repliedAt,
                on: snap?.on ?? false,
                sec: snap?.sec ?? 0,
                subs: snap?.subs.run ?? 0,
                isActive: slot.playback.isActive,
                isPaused: slot.playback.isPaused,
                canReplay: slot.playback.canReplay,
                // 进度也走观察：轮询每拉回一份（在播时 1 秒一次）就重算一次卡片 ——
                // 绝大多数时候 `playMark` 沿用上一份，内容相等，Policy 判 skip，不会每秒推。
                played: slot.playback.played,
                total: slot.playback.total,
                fid: slot.playback.fid,
                playback: slot.playback,
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

            // 「等你回话」锁屏提醒：必须在 makeState 之前判 —— makeState 会把 moodMemo 改成这一刻的脸，
            // 之后就拿不到「上一刻是什么脸」了。
            let prevMood = moodMemo?.room == i.room ? moodMemo?.mood : nil
            if i.mood != .waiting {
                pendingAlert = nil
            } else if CCLiveActivityPolicy.shouldAlert(
                previousMood: prevMood, mood: i.mood, room: i.room, wait: i.wait,
                lastAlert: lastAlert,
                // 卡片跟着当前房间走，所以「在前台」就是「正看着这个房间」。
                appViewingRoom: UIApplication.shared.applicationState == .active,
                now: now) {
                lastAlert = .init(room: i.room, text: i.wait.trimmingCharacters(in: .whitespacesAndNewlines), at: now)
                pendingAlert = (i.room, CCLiveActivityPolicy.alertBody(wait: i.wait))
            }

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
                if let t = CCQuickReply.repliedRecheck(at: i.repliedAt, now: now) { wakeAt.append(t) }
            }
            // 提醒没推出去、而卡片已经没东西可推（推过了 / 开卡时直接带进去了 / 没卡）⇒ 作废。
            if activityID == nil || lastPushed == state { pendingAlert = nil }
            if let f = lastStartFailure, life == .start || life == .rollover {
                wakeAt.append(f.addingTimeInterval(CCLiveActivityPolicy.startRetry))
            }
            // 只要将来的：换卡失败时「开卡满 7.5 小时」那个时刻已经过去了，
            // 留着它会让闹钟每 50 毫秒响一次（重试节奏由 startRetry 那个时刻管）。
            scheduleWake(wakeAt.filter { $0 > now }.min(), now: now)

            holdPolling(activityID != nil ? i.playback : nil)
        }

        /// 让「有卡时挂号、没卡时退号、换房间时换着挂」成立。每次 `apply` 末尾调，幂等。
        private func holdPolling(_ want: CCPlaybackRemote?) {
            guard want !== pollingRemote else { return }
            pollingRemote?.releasePolling(Self.pollOwner)
            want?.acquirePolling(Self.pollOwner)
            pollingRemote = want
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
            let play = CCLiveActivityPolicy.playMark(
                isActive: i.isActive, isPaused: i.isPaused, played: i.played, total: i.total, fid: i.fid,
                previous: playMemo?.room == i.room ? playMemo?.mark : nil, now: now)
            playMemo = (i.room, play)
            let line = CCQuickReply.repliedLine(text: i.repliedText, at: i.repliedAt, now: now)
            return CCLiveActivityPolicy.makeState(
                room: i.room, mood: i.mood, skin: i.skin, presence: i.presence,
                snapHeadline: i.snapHeadline, runningSubtasks: i.subs, timerStart: start,
                isActive: i.isActive, isPaused: i.isPaused, canReplay: i.canReplay,
                peers: i.peers, play: play, wait: i.wait, repliedLine: line, options: i.opts, labels: i.optl, emoji: i.emoji)
        }

        // MARK: - ActivityKit

        /// 一份卡片内容的一行摘要（诊断用）：状态行 · 心情 · 播放样子。
        nonisolated private static func brief(_ s: CCLiveActivityState) -> String {
            let play: String
            switch s.playDisplay {
            case .hidden: play = "无进度"
            case .running: play = "在播"
            case .growing: play = "在播(生成中)"
            case let .still(p, t): play = "停@\(Int(p))/\(t.map { String(Int($0)) } ?? "?")"
            }
            return "\(s.headline) · \(s.mood) · \(play)\(s.quickReplyShown ? " · 快捷回复" : "")"
        }

        /// 判断「系统收没收」用的指纹：卡片上看得见的字段，时间取整到秒。
        nonisolated private static func landedKey(_ s: CCLiveActivityState) -> String {
            let sec: (Date?) -> String = { $0.map { String(Int($0.timeIntervalSince1970.rounded())) } ?? "-" }
            return [brief(s), s.room, s.avatar ?? "-", sec(s.playStart), sec(s.timerStart),
                    s.playTotal.map { String(Int($0.rounded())) } ?? "-",
                    s.waitText ?? "-", (s.replyOptions ?? []).joined(separator: "|"),
                    s.peers.map { "\($0.name)\($0.dot)" }.joined(separator: ",")].joined(separator: "§")
        }

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
            CCLiveActivityLog.shared.log("卡片没了（已开 \(Int(age)) 秒）→ \(dismissedByUser ? "当成用户划掉" : "系统到点收走")")
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
                CCLiveActivityLog.shared.log("开卡 \(state.room)")
                return true
            } catch {
                lastStartFailure = now
                CCLiveActivityLog.shared.log("⚠️ 开卡失败（后台时开不了是正常的）：\(error)")
                return false
            }
        }

        private func push(_ state: CCLiveActivityState, now: Date, wakeAt: inout [Date]) {
            switch CCLiveActivityPolicy.push(next: state, last: lastPushed, lastPushAt: lastPushAt, now: now) {
            case .skip:
                return
            case let .wait(dt):
                wakeAt.append(now.addingTimeInterval(dt))
                CCLiveActivityLog.shared.log("等 \(String(format: "%.1f", dt))s 再推（节流）")
                return
            case .now:
                break
            }
            // 先记账再 await：推的途中再来一份，节流要按这一次算。
            lastPushed = state
            lastPushAt = now
            let id = activityID
            let content = ActivityContent(state: state, staleDate: CCLiveActivityPolicy.staleDate(now: now))
            // 等你回话的那一下：带 AlertConfiguration 推 —— 系统据此展开灵动岛、点亮锁屏、响一声。
            let alert = pendingAlert
            pendingAlert = nil
            let brief = Self.brief(state)
            CCLiveActivityLog.shared.log("推 → \(brief)\(alert != nil ? " ＋提醒" : "")")
            Task {
                guard let a = Self.find(id) else {
                    CCLiveActivityLog.shared.log("⚠️ 推不出去：系统里找不到这张卡")
                    return
                }
                if let alert {
                    // 标题 / 正文是运行时字符串：走字符串插值进 LocalizedStringResource
                    // （没有对应的本地化条目，系统按原文显示）。
                    await a.update(content, alertConfiguration: AlertConfiguration(
                        title: "\(alert.title)", body: "\(alert.body)", sound: .default))
                } else {
                    await a.update(content)
                }
                // 回读系统手里那份：跟刚推的不一样 ＝ 系统没收（节流 / 丢弃），不是我们没推。
                // **现取一份新的**，不复用上面那个 `a` —— 它已经被 `update` 拿走（sending），
                // 再碰它 Swift 6 编不过（见文件头「Activity 对象怎么拿」）。
                //
                // ## 没收就补推（2026-10-06 诊断页实锤）
                //
                // Chris 截的事件流：两次推隔 8 秒以上的都「系统已收」；隔 1~3 秒的连着几次
                // 「系统没收：手里还是上一份」—— **系统把太密的更新丢了**。最要命的是最后一次被丢：
                // 之后没有新变化就再也不推，卡片永远停在上一份（「在飞书点了重播、第二遍就失联」）。
                // ⇒ 稍等再回读一次（刚推完立刻读可能还没落地），还不一样、而且我们没有更新的一份要推，
                //    就把「上次推的」作废、定个闹钟重推 —— 最后一份一定会落地。
                try? await Task.sleep(for: .seconds(1))
                guard let b = Self.find(id) else { return }
                // 不直接比整个结构体：里面的 Date 经系统编解码一圈可能差到亚毫秒，会被误判成「没收」
                // 然后一直补推。比 `landedKey`（看得见的字段 ＋ 取整到秒的时间）。
                let landed = Self.landedKey(b.content.state) == Self.landedKey(state)
                let st = "\(b.activityState)"
                if landed {
                    self.missStreak = 0
                    CCLiveActivityLog.shared.log("系统已收（\(st)）")
                    return
                }
                CCLiveActivityLog.shared.log("⚠️ 系统没收：手里还是 \(Self.brief(b.content.state))（\(st)）")
                // 期间又推过更新的一份：由那一份自己回读负责，这里不管。
                guard self.lastPushed == state, self.activityID == id else { return }
                self.missStreak += 1
                // 连着被丢就退避（2、4、8…封顶 16 秒）：系统在限流时追着推只会继续被丢。
                let backoff = min(16, pow(2, Double(min(self.missStreak, 4))))
                self.lastPushed = nil
                CCLiveActivityLog.shared.log("\(Int(backoff))s 后补推")
                self.scheduleWake(Date().addingTimeInterval(backoff), now: Date())
            }
        }

        /// 连着「系统没收」几次了（补推退避用）。收了就清零。
        private var missStreak = 0

        private func endCard(id: String? = nil) {
            let target = id ?? activityID
            if id == nil || id == activityID { forget() }
            guard let target else { return }
            CCLiveActivityLog.shared.log("结束卡片")
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
                CCLiveActivityLog.shared.log("按钮 toggle \(room) [\(r.before)] → \(r.action)：\(slot.playback.lastError ?? "ok")")
            case .replay:
                await slot.playback.replay()
                CCLiveActivityLog.shared.log("按钮 replay \(room) → \(slot.playback.lastError ?? "ok")")
            case .activate:
                // 卡片的重算靠观察 activeName（readInputs 读了 rooms.active），不用手动 sync。
                rooms?.activate(slot.name)
                print("[CCLiveActivity] 按钮 切到 \(room)")
            }
        }

        /// 快捷回复：**走 app 本来的文字通道** —— 跟聊天框（`ChatInputView`）同一个
        /// `session.send(text:)`，LiveKit 文本流 `lk.chat`。bot 本体（`<房间名>-speaker`）收下后
        /// 注入它自己的对话；语音助手不接（服务端契约见 CloseCrab `docs/livekit-cross-end-contract.md`）。
        ///
        /// SDK 的 send 顺手把这句记进本房间的聊天记录（loopback），回到 app 里能看到 —— 跟手打一样。
        ///
        /// ⚠️ 文本流是单向的：`send` 返回非 nil 只说明**发出去了**，不说明 bot 收下了
        /// （例如 bot 那边没重启、还不认 `lk.chat`）。「已回复」按「已发出」显示。
        private func quickReply(room: String, text: String) async {
            guard let slot = rooms?.slots.first(where: { $0.name == room }) else {
                print("[CCLiveActivity] 快捷回复：房间 \(room) 不在（app 可能刚被系统拉起，还没连）")
                return
            }
            // 跟主界面那两颗按钮走同一个出口（`CCQuickReplySender`）：「已回复」的时刻记在槽位上，
            // 主界面和卡片看到的是同一份 —— 在锁屏上点了，回到 app 也是「已回复」。
            // 卡片的重算靠观察那两个属性（readInputs 里读了），不用在这里手动 sync。
            let ok = await slot.quickReply.send(text)
            print("[CCLiveActivity] 快捷回复 \(room)：\(text) → \(ok ? "已发出" : (slot.quickReply.lastError ?? "失败"))")
        }
    }

#endif
