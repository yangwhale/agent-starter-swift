import Foundation

/// 锁屏实时活动的全部规则：什么时候开、什么时候关、什么时候换卡、什么时候推更新、
/// 卡片上写什么。**只依赖 Foundation，离线可测**（`Tests/CCLiveActivityPolicyTests.swift`）。
///
/// 动手的那一层（`CCLiveActivity`，ActivityKit）只照这里的判定执行 ——
/// 那一层 Linux 上编不了，写错了只有装到手机上锁屏才看得出来，所以判定都搬到这里。
///
/// ## 几条容易写反、日常又看不出来的
///
/// - **用户在锁屏上把卡片划掉了，这一轮连接里就别再开。** 不然每推一次更新它就又冒出来，
///   像个关不掉的弹窗。下一次按「开始」才重新允许（`dismissedByUser` 由调用方在
///   `wantConnected` 从假变真时清掉）。
/// - **断线重连期间卡片不关。** 判据是「用户想连着」（`wantConnected`），不是「此刻连着」——
///   重连时卡片上是那张迷糊找人的脸，这正是锁屏上该看到的；关掉再开会让卡片闪没。
/// - **状态没变也要定期重推一次。** 每次推都把过期时间往后续 15 分钟；bot 安静地闲着
///   半小时不等于 app 死了，不续的话卡片会自己变成「已断开」。
/// - **节流是「至少隔 1 秒」，不是「丢掉 1 秒内的变化」。** 1 秒内来的最后一份必须
///   在窗口到点时补推，否则停在中间态上（比如停在「在说话」，而它早说完了）。
nonisolated enum CCLiveActivityPolicy {
    /// 两次推更新至少隔多久。
    static let minUpdateInterval: TimeInterval = 1
    /// 卡片多久没收到更新就算过期（显示「已断开」）。每次推都续。
    static let staleAfter: TimeInterval = 15 * 60
    /// 状态没变时多久重推一次（只为续过期时间）。**必须比 `staleAfter` 短**，测试钉着。
    static let keepAliveAfter: TimeInterval = 10 * 60
    /// 一张卡最多用多久就换新的。系统上限是 8 小时（到点强制结束），留半小时余量。
    static let rolloverAfter: TimeInterval = 7.5 * 3600
    /// 系统给一张卡的硬上限（到点强制结束）。
    static let systemMaxAge: TimeInterval = 8 * 3600
    /// 开卡 / 换卡失败（app 在后台时开不了新卡）之后多久再试。回前台时调用方会直接清零。
    static let startRetry: TimeInterval = 5 * 60
    /// 计时起点的抖动容忍。服务端的 `sec` 是发出那一刻的值、属性限频 0.5 秒，
    /// 每份快照反推出来的起点会差几百毫秒 —— 不吃掉的话每份快照都算「变了」，白推一次。
    static let timerTolerance: TimeInterval = 2
    /// 状态行最多几个字符（ActivityKit 整份内容上限 4 KB，这是最长的字段）。
    static let headlineMax = 80
    /// 卡片上最多画几个其他房间的小圆点。
    static let maxPeers = 5
    /// 「到点」的容差。闹钟按 `窗口 − 已过时间` 定，醒来再算一遍时浮点舍入可能差一丁点
    /// （0.99999999 秒）—— 不留容差就会再定一个 1e-16 秒的闹钟，而那个加法会被舍掉，
    /// 等于原地打转（测试里的模拟器真的转死过）。差不到 5 毫秒算到点。
    static let timingSlack: TimeInterval = 0.005

    // MARK: - 开 / 关 / 换

    enum Lifecycle: Equatable, Sendable {
        /// 没卡，也不该有。
        case none
        /// 该有卡但还没有：开一张。
        case start
        /// 有卡，继续用（推不推更新另看 `push`）。
        case keep
        /// 有卡但不该有了：结束。
        case end
        /// 这张卡快到 8 小时了：开新的、结束旧的。
        case rollover
    }

    /// - Parameters:
    ///   - enabled: 系统设置里允许实时活动（`ActivityAuthorizationInfo().areActivitiesEnabled`）。
    ///   - wantConnected: 用户按过「开始」、还没挂断（`CCRooms.wantConnected`）。
    ///   - room: 当前房间名，空串＝还没选。
    ///   - hasCard: 手上有一张还活着的卡。
    ///   - cardStartedAt: 那张卡是什么时候开的。
    ///   - dismissedByUser: 这一轮连接里用户在锁屏上划掉过卡片。
    static func lifecycle(enabled: Bool, wantConnected: Bool, room: String,
                          hasCard: Bool, cardStartedAt: Date?, dismissedByUser: Bool,
                          now: Date) -> Lifecycle {
        let want = enabled && wantConnected && !room.isEmpty && !dismissedByUser
        guard want else { return hasCard ? .end : .none }
        guard hasCard else { return .start }
        if let s = cardStartedAt, now.timeIntervalSince(s) >= rolloverAfter { return .rollover }
        return .keep
    }

    /// 开卡 / 换卡失败之后现在该不该再试。没失败过＝该试；时钟往回拨（`now` 早于上次）＝该试 ——
    /// 卡在一个未来时刻上就永远不会再试，而 8 小时一到系统会把旧卡强制收走。
    static func shouldRetryStart(lastFailure: Date?, now: Date) -> Bool {
        guard let last = lastFailure else { return true }
        let dt = now.timeIntervalSince(last)
        return dt < 0 || dt >= startRetry
    }

    /// 手上的卡不是我们结束的、却没了：算不算用户在锁屏上划掉的。
    ///
    /// - 系统开关关着（用户去「设置」里关了实时活动）⇒ 不算：那是关开关，不是划卡；
    ///   开关再打开时应该立刻回来，而不是等到下一次按「开始」。
    /// - 没到系统 8 小时上限就没了 ⇒ 算。到了上限 ⇒ 是系统收走的，下次有机会就开新的。
    static func goneMeansUserDismissed(age: TimeInterval, enabled: Bool) -> Bool {
        enabled && age < systemMaxAge
    }

    // MARK: - 推不推更新

    enum Push: Equatable, Sendable {
        /// 不用推。
        case skip
        /// 现在推。
        case now
        /// 过这么多秒再推（节流窗口没到）。
        case wait(TimeInterval)
    }

    /// 这一份要不要推。泛型只要 `Equatable` —— 测试拿整数就能把节流规则钉死。
    static func push<S: Equatable>(next: S, last: S?, lastPushAt: Date?, now: Date) -> Push {
        guard let last, let at = lastPushAt else { return .now }
        let dt = now.timeIntervalSince(at)
        // 时钟往回拨：按「刚好过了窗口」处理。算 wait 会得到一个很长的等待，
        // 那段时间里卡片就冻住了。
        if dt < 0 { return next == last ? .skip : .now }
        if next == last { return dt >= keepAliveAfter - timingSlack ? .now : .skip }
        return dt >= minUpdateInterval - timingSlack ? .now : .wait(minUpdateInterval - dt)
    }

    /// 这一次推的过期时间。
    static func staleDate(now: Date) -> Date { now.addingTimeInterval(staleAfter) }

    /// 时间相关的心情（「刚干完」3 秒、「在说话」句间宽限 1.5 秒）到点之后要重算一次 ——
    /// 这两样不是被观察的属性变化，没人会来通知「窗口过了」，卡片会停在笑脸上。
    /// 返回最近的那个到点时刻；都不在窗口里就是 nil。
    static func nextRecheck(now: Date, finishedAt: Date?, speechEndedAt: Date?) -> Date? {
        var out: Date?
        if let f = finishedAt, CCFaceMood.isWithinDoneWindow(finishedAt: f, now: now) {
            out = f.addingTimeInterval(CCFaceMood.doneWindow)
        }
        if CCFaceMood.isWithinSpeakingHold(speechEndedAt: speechEndedAt, now: now),
           let e = speechEndedAt {
            let t = e.addingTimeInterval(CCFaceMood.speakingHold)
            out = out.map { min($0, t) } ?? t
        }
        return out
    }

    // MARK: - 语音播放进度

    /// 在播时，「按卡片上的起点推算的已播秒数」跟服务端报的差多少才重推。
    /// 服务端每秒报一次、RPC 往返几百毫秒，每次反推出来的起点都会抖 —— 不吃掉的话
    /// 每秒推一次，正是要避免的。超过 2 秒才说明真偏了（卡住等生成、拖动、网络慢了一大截）。
    static let playDriftTolerance: TimeInterval = 2
    /// 总长变化超过多少才重推。生成完那一刻服务端给的总长可能还会再修正一点点。
    static let playTotalTolerance: TimeInterval = 1

    /// 卡片上那条进度「上一次推的是什么」。`playMark` 返回跟上次**同一个值**就意味着
    /// 进度这一项不用推（卡片内容整体相等 ⇒ `push` 判 skip）。
    nonisolated struct PlayMark: Equatable, Sendable {
        /// 这是哪一段（`CCPlaybackRemote.fid`）。换了一段 ⇒ 一定重推。
        var fid: String
        /// 在播：这一段从头开始播的时刻。
        var start: Date?
        /// 不在播（暂停 / 播完）：停在第几秒。
        var played: Double?
        /// 总长，nil ＝ 还在生成。
        var total: Double?

        static let none = PlayMark(fid: "", start: nil, played: nil, total: nil)
        var isPlaying: Bool { start != nil }
    }

    /// 由服务端这一次的进度（`CCPlaybackRemote` 的 isActive / isPaused / played / total / fid）
    /// 和上一次推出去的那份，算这一次卡片上该写的进度。
    ///
    /// **能沿用上一次就沿用**（返回 `previous` 原值）—— 只有下面这些才换新值、触发一次推：
    /// 开始播 / 暂停 / 继续 / 播完（在播 ⇄ 不在播）、换了一段、总长从未知变已知（或反过来）、
    /// 总长变化 > 1 秒、在播时已播秒数跟按起点推算的差 > 2 秒；停着时显示的整秒数变了。
    ///
    /// - 有没有东西：`isActive || !fid.isEmpty`（播完了 fid 还留着 ⇒ 还能重播，进度条照画）。
    /// - 在播：`isActive && !isPaused`。服务端的 `paused` 在不活跃时是残值，不算（跟 makeState 一致）。
    static func playMark(isActive: Bool, isPaused: Bool, played: Double, total: Double?, fid: String,
                         previous: PlayMark?, now: Date) -> PlayMark {
        guard isActive || !fid.isEmpty else { return .none }
        let p = played.isFinite ? max(0, played) : 0
        let t = total.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let prev = previous.flatMap { $0.fid == fid && totalsClose($0.total, t) ? $0 : nil }

        if isActive && !isPaused {
            let start = now.addingTimeInterval(-p)
            if let prev, let ps = prev.start, abs(ps.timeIntervalSince(start)) <= playDriftTolerance {
                return prev
            }
            return PlayMark(fid: fid, start: start, played: nil, total: t)
        }
        // 停着：数字是死的，只看显示出来的整秒变没变（暂停时拖了一下也要跟上）。
        if let prev, prev.start == nil, let pp = prev.played,
           Int(pp.rounded()) == Int(p.rounded()) {
            return prev
        }
        return PlayMark(fid: fid, start: nil, played: p, total: t)
    }

    /// 两个总长算不算「一样」：都未知；或都已知且差不超过 `playTotalTolerance`。
    /// 一个已知一个未知 ⇒ 不一样（生成完了，进度条该出来了）。
    static func totalsClose(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) <= playTotalTolerance
        default: return false
        }
    }

    // MARK: - 等你回话：锁屏提醒（2026-10-05）

    /// 同一句 wait 多久内不重复提醒。服务端的状态是属性推送，重连、补发、
    /// 「等你 → 在听你说 → 等你」（按住说话又松开）都可能把同一句再送来一遍 ——
    /// 提醒会亮屏、响声，重复一次就很烦。
    static let alertRepeatWindow: TimeInterval = 60
    /// 提醒正文（wait 那句）最多几个字符。横幅和灵动岛展开都只放得下一两行。
    static let alertBodyMax = 60

    /// 上一次提醒的是哪个房间的哪句话、什么时候。
    nonisolated struct AlertMark: Equatable, Sendable {
        var room: String
        /// 去过空白的 wait 原文（不是截短后的正文 —— 两句前 60 字一样的不同问题不该互相挡）。
        var text: String
        var at: Date
    }

    /// 这一刻该不该用带提醒的 update（灵动岛自动展开、锁屏亮起、提示音）。
    ///
    /// 全部满足才提醒：
    /// - **跃迁**：上一刻的脸不是「等你」、这一刻是。一直挂着的「等你」只在开始那一下提醒。
    /// - 上一刻**不是**睡着 / 找网络、也不是第一次看到这个房间（`previousMood == nil`）——
    ///   断线重连回来看到的是早就挂着的那句，不是「刚开始等你」（跟 `CCFaceEvent.detect`
    ///   「首份状态不算事件」同一个理由：那句你断线前已经被提醒过了）。
    /// - app 不在前台看着这个房间（`appViewingRoom == false`）—— 正看着屏幕，脸已经变了，
    ///   app 里还有叮声（`CCFaceChime`），锁屏提醒是给**没在看**的时候的。
    /// - wait 去空白后非空，且同一房间同一句 60 秒内没提醒过（时钟往回拨不算「刚提醒过」）。
    static func shouldAlert(previousMood: CCFaceMood?, mood: CCFaceMood, room: String, wait: String,
                            lastAlert: AlertMark?, appViewingRoom: Bool, now: Date) -> Bool {
        guard mood == .waiting, let prev = previousMood, prev != .waiting else { return false }
        guard prev != .asleep, prev != .searching else { return false }
        guard !appViewingRoom else { return false }
        let text = wait.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let l = lastAlert, l.room == room, l.text == text {
            let dt = now.timeIntervalSince(l.at)
            if dt >= 0 && dt < alertRepeatWindow { return false }
        }
        return true
    }

    /// 提醒的正文：wait 那句去空白、截到 `alertBodyMax`。标题是 bot 名（＝房间名），调用方直接用。
    static func alertBody(wait: String) -> String {
        truncate(wait.trimmingCharacters(in: .whitespacesAndNewlines), max: alertBodyMax)
    }

    // MARK: - 快捷回复（2026-10-05）

    /// 回复发出后状态行显示「已回复：没问题，请继续」多久（完整原句，不是按钮上的简写）。
    static let repliedShowFor: TimeInterval = 3

    /// 刚回复过的那句还在显示窗口里吗：`[at, at + 3 秒)`，左闭右开；时钟往回拨不算。
    /// 在窗口里返回整句状态行（「已回复：没问题，请继续」），否则 nil。
    static func repliedLine(text: String?, at: Date?, now: Date) -> String? {
        guard let text, let at else { return nil }
        let dt = now.timeIntervalSince(at)
        guard dt >= 0, dt < repliedShowFor else { return nil }
        return "已回复：\(text)"
    }

    /// 「已回复」到点要撤下 —— 这不是属性变化，没人通知，得自己定闹钟。窗口外返回 nil。
    static func repliedRecheck(at: Date?, now: Date) -> Date? {
        guard let at, repliedLine(text: "", at: at, now: now) != nil else { return nil }
        return at.addingTimeInterval(repliedShowFor)
    }

    // MARK: - 卡片上写什么

    /// 计时起点。
    ///
    /// - bot 在跑一轮（`on`）：从这一轮开始算（`now − sec`）—— 「已经干了多久」。
    /// - 否则：从进入当前这张脸的时刻算（等你等了多久、闲了多久）。
    ///
    /// 跟上一次的起点差不到 `timerTolerance` 就沿用上一次的（理由见那个常量）。
    static func timerStart(on: Bool, sec: Double, now: Date, previous: Date?, moodSince: Date) -> Date {
        let candidate = on ? now.addingTimeInterval(-max(0, sec)) : moodSince
        if let p = previous, abs(p.timeIntervalSince(candidate)) <= timerTolerance { return p }
        return candidate
    }

    /// 状态行。
    ///
    /// 睡着 / 找网络时**不用 bot 状态** —— 那是断线前的残值，跟脸的规则一样
    /// （`CCFaceMood.derive` 没连上时不看 `wait` / `on`）。脸写着「睡着了」、
    /// 底下却写着「在读某某文件」，看的人会信后者。
    ///
    /// **在说话 / 在听你说 / 空闲 也用脸的说法，不用 bot 状态**（Chris 2026-10-05 截图：
    /// 脸是笑眼在说话，底下却一直写「空闲」）。bot 状态只描述「这个回合在不在干活」：
    /// 回合一结束它就回「空闲」，而语音是回合结束**之后**才开始播的 —— 所以说话的那一整段
    /// bot 状态都是「空闲」。只有「在查东西」「等你」这两种，bot 状态那句才比脸说得具体。
    static func headline(mood: CCFaceMood, snapHeadline: String?) -> String {
        switch mood {
        case .asleep, .searching, .speaking, .listening, .idle:
            return mood.spoken
        default:
            let h = (snapHeadline ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return h.isEmpty ? mood.spoken : truncate(h, max: headlineMax)
        }
    }

    /// 按字符（不是字节、不是 UTF-16）截，超了在末尾放一个「…」，总长恰好 `max`。
    static func truncate(_ s: String, max: Int) -> String {
        guard max > 0 else { return "" }
        guard s.count > max else { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    /// 拼一份卡片内容。
    ///
    /// - skin: 房间没选活脸（nil）时给 classic —— 卡片上总得有张脸，而扩展读不到
    ///   app 里存的 emoji / 照片（没有 App Groups）。
    /// - peers: 全部房间的小圆点（含当前房间也行，这里会去掉），按传入顺序保留前 `maxPeers` 个。
    static func makeState(room: String, mood: CCFaceMood, skin: CCFaceSkin?, presence: CCPresenceDot,
                          snapHeadline: String?, runningSubtasks: Int, timerStart: Date,
                          isActive: Bool, isPaused: Bool, canReplay: Bool,
                          peers: [(name: String, dot: CCPresenceDot)],
                          play: PlayMark = .none,
                          wait: String = "", repliedLine: String? = nil) -> CCLiveActivityState {
        // 子任务数跟状态行同一条规矩：断线时是残值，不显示。
        let live = mood != .asleep && mood != .searching
        // 等你回话：卡片上把暂停 / 重播换成快捷回复。刚回复过（「已回复」还在显示）就先不给，
        // 免得 bot 还没来得及清掉 wait 时又被按一次。
        let waitTrim = wait.trimmingCharacters(in: .whitespacesAndNewlines)
        let quick = mood == .waiting && repliedLine == nil
        var s = CCLiveActivityState(
            room: room,
            mood: mood.rawValue,
            skin: (skin ?? .classic).rawValue,
            presence: presence.rawValue,
            headline: repliedLine.map { truncate($0, max: headlineMax) }
                ?? headline(mood: mood, snapHeadline: snapHeadline),
            subtasks: live ? max(0, runningSubtasks) : 0,
            timerStart: timerStart,
            isPlaying: isActive && !isPaused,
            isPaused: isActive && isPaused,
            canReplay: canReplay,
            peers: peers.filter { $0.name != room }.prefix(maxPeers)
                .map { CCLiveActivityState.Peer(name: $0.name, dot: $0.dot.rawValue) },
            // 起点只在「在播」时给、停住的秒数只在「不在播」时给 —— 两个判据都跟上面
            // isPlaying 同源，扩展那边不会碰到「说在播、却只有暂停秒数」的组合。
            playStart: isActive && !isPaused ? play.start : nil,
            playTotal: play.total,
            playedAtPause: isActive && !isPaused ? nil : play.played
        )
        // 两个新字段**不在等你时写 nil 而不是 false / 空串**：JSON 里就不出现这两个键，
        // 体积不变、也就等于旧 app 的格式（`playStart` 那三个同一个理由）。
        s.showsQuickReply = quick ? true : nil
        s.waitText = mood == .waiting && !waitTrim.isEmpty ? truncate(waitTrim, max: headlineMax) : nil
        return s
    }
}
