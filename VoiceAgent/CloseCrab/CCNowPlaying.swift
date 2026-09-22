#if os(iOS)

    import MediaPlayer

    /// 把 bot 的说话接到**系统的媒体控制**上 —— 锁屏那张卡片、控制中心、
    /// 车机方向盘，以及 Chris 真正要的那个：**捏一下 AirPods 就暂停/继续。**
    ///
    /// Chris 2026-09-22 23:39：
    /// 「那这个控件能跟 iPhone 的那个媒体播放控件连上吗，
    ///  目的就是用我的 AirPods 耳机上面的那个按钮来控制开始和暂停。」
    ///
    /// ## 这一层只做「转接」，不做播放
    ///
    /// 音频是服务端合成后推下来的实时流，暂停必须回一趟服务端
    /// （理由见 `CCPlaybackRemote` 的类型注释）。所以这里收到系统的
    /// 「播放/暂停」之后，转手调的还是那六个 RPC 里的两个。
    ///
    /// ⇒ **捏 AirPods 和点飞书卡片上那颗暂停，走的是同一条路。**
    ///
    /// ## 为什么这件事本来就快成了
    ///
    /// 系统把命令交给谁，看的是「谁是当前的 Now Playing app」，而当选要两个条件：
    ///
    /// | 条件 | 我们的状态 |
    /// |---|---|
    /// | 有一个**激活的、媒体类的**音频会话 | ✅ bot 说话而我们没开麦时，`CCAudioSessionPolicy` 把类别设成 `.playback` —— 正是媒体类 |
    /// | 注册了 `MPRemoteCommandCenter` 的处理器 | ❌ 一直没有。**这个文件就是补这一块** |
    /// | `Info.plist` 有 `UIBackgroundModes: audio` | ✅ 早就有（为后台收音频开的）|
    ///
    /// ⇒ 三缺一。**不是从零做一个功能，是把最后一根线接上。**
    ///
    /// ## ⚠️ 已知的边界，两条，都没在真机上验过
    ///
    /// **一、开着麦的时候大概率不灵。** 我们按住说话时类别会切成
    /// `.playAndRecord`，那更像「通话」而不是「放音乐」，系统可能把耳机按键
    /// 留给通话控制、不转交给我们。**这不影响主场景** —— 你捏 AirPods 的时刻
    /// 正是 bot 在说、你没在说的时刻，那时候类别就是 `.playback`。
    ///
    /// **二、暂停之后还能不能再捏一下继续，取决于会话有没有被释放。**
    /// `CCAudioSessionPolicy` 在「既不放音也不录音」时会**主动释放**会话
    /// （那是让出麦克风那条修复的一部分）。风险是：暂停 ⇒ 没声音 ⇒ 引擎关播放
    /// ⇒ 会话释放 ⇒ 丢掉 Now Playing ⇒ **能捏停，捏不动继续**。
    ///
    /// **服务端这半边已经查实，结论是：暂停不碰音轨。**
    /// `livekit_out.py` 里那条 `bot-speech` 轨是**连接时发布一次、
    /// 断开才收**（`publish_track` 在 `room.connect` 之后紧接着，
    /// 全文件没有任何 `unpublish`）。而 `player.py` 的 `pause()`
    /// 做的全部事情是 `self._state = PAUSED` —— 只是不再喂帧，
    /// 音轨照样发布着、客户端照样订阅着。
    ///
    /// ⇒ **暂停不是「取消订阅」，只是「这条轨暂时是静音的」。**
    /// 所以它不会通过「音轨没了」这条路去关播放引擎。
    ///
    /// ⚠️ **剩下的未知只有一条**：LiveKit 的引擎会不会因为
    /// 「订阅着但长时间没数据」而自己关掉播放。这条我没查
    /// （要读 SDK 内部的 WebRTC 桥接）。但它的后果被限住了 ——
    /// 最坏是「停太久之后失效」，**不是「一停就失效」**。
    ///
    /// ⇒ 仍然**不预先加「暂停时钉住会话」的开关**：为一个已经缩到
    /// 边角的问题加机制不划算，而多加的机制会在别处发作
    /// （麦克风那条链路刚被这类东西咬过）。等真机上看到再说。
    ///
    /// ⇒ 顺带一条方法论：**「我判断不会」和「我查过不会」差得很远。**
    /// 这条边界原来整条是判断，花了三分钟读服务端代码之后，
    /// 一半变成了事实、另一半的严重性降了一档。查证通常比想象中便宜。
    ///
    /// ## 不编分母（跟服务端同一条规矩）
    ///
    /// 音频还在生成时服务端如实回 `total: null`。这里**不猜一个时长** ——
    /// 改成告诉系统「这是直播流」（`IsLiveStream`），锁屏就不会画一条
    /// 骗人的进度条。跟 `CCPlaybackBar` 里那条注释是同一个理由。
    @MainActor
    final class CCNowPlaying {
        static let shared = CCNowPlaying()
        private init() {}

        /// 命令该转给谁。**弱引用** —— 房间销毁时这里不该把它吊着。
        private weak var target: CCPlaybackRemote?
        /// 卡片上显示哪个房间。
        private var room = ""
        /// 处理器只注册一次。`MPRemoteCommandCenter` 是全进程单例，
        /// 重复 `addTarget` 会挂出多个处理器 —— 一次按键触发好几回。
        private var wired = false

        // MARK: - 挂接

        /// 把系统媒体控制指向某个房间的播放器。
        ///
        /// **由 `CCRooms.activate()` 调** —— 五个房间同时挂着时，
        /// 系统只有一张 Now Playing 卡片，**必须有人决定它属于谁**。
        /// 选「当前房间」而不是「正在说话的房间」：后者会在两个 bot
        /// 交替说话时来回跳，而你捏耳机想控制的永远是你正在听的那个。
        func attach(_ remote: CCPlaybackRemote?, room: String) {
            wireIfNeeded()
            target = remote
            self.room = room
            // 换了房间就立刻按新房间的状态重画一次，别让卡片停在上一个房间上。
            if let remote { publish(from: remote) } else { clear() }
        }

        /// 刷新卡片。**由 `CCPlaybackRemote.refresh()` 每次拉完进度调。**
        ///
        /// ⚠️ 带上调用者本人做校验：五个房间都在轮询，
        /// **只有挂接上的那个有资格改卡片**。不校验的话后台房间会把
        /// 前台房间的卡片覆盖掉，而且是随机哪个先轮询到就听谁的。
        func publish(from remote: CCPlaybackRemote) {
            guard remote === target else { return }

            // 既没在播、也没有可重播的东西 ⇒ 让出卡片。
            //
            // **不赖着不走**：Now Playing 只有一张，我们占着它，用户的
            // 音乐 app 就从锁屏上消失了。没东西可控的时候占着它是耍流氓。
            guard remote.isActive || remote.canReplay else {
                clear()
                return
            }

            var info: [String: Any] = [
                MPMediaItemPropertyTitle: room,
                MPMediaItemPropertyArtist: "CloseCrab",
                // 暂停时速率必须是 0。**这一位就是锁屏上那颗图标的朝向** ——
                // 不给的话系统按 1 算，暂停之后卡片上还画着「正在播」。
                MPNowPlayingInfoPropertyPlaybackRate: remote.isPaused ? 0.0 : 1.0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: remote.played,
            ]

            if let total = remote.total, total > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = total
            } else {
                // ⚠️ **不编一个分母。** 服务端在音频还没生成完时如实回 null，
                //    这里跟着如实说「长度未知」。`IsLiveStream` 正是为这个存在的：
                //    锁屏会把进度条换成一个走时的计数器，而不是一条
                //    看起来「快播完了」的假进度。
                info[MPNowPlayingInfoPropertyIsLiveStream] = true
            }

            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        /// 交还卡片。断开连接、或者这个房间彻底没东西可播时调。
        func clear() {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }

        // MARK: - 注册处理器

        /// ⚠️ **不需要 `beginReceivingRemoteControlEvents()`。**
        /// 那个是给老的 `UIResponder.remoteControlReceived` 那条路用的；
        /// `MPRemoteCommandCenter` 自己就是注册动作。两条路混着用会重复响应。
        private func wireIfNeeded() {
            guard !wired else { return }
            wired = true

            let center = MPRemoteCommandCenter.shared()

            // ⭐ **AirPods 捏一下发的就是这一条。** 蓝牙耳机、有线耳机的中键、
            //    车机的播放/暂停键，绝大多数都走 toggle 而不是分开的 play/pause。
            //    只注册 play 和 pause 的话，耳机按键会**完全没反应** ——
            //    而那正是 Chris 要的唯一一个交互。
            center.togglePlayPauseCommand.isEnabled = true
            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                self?.toggle() ?? .noActionableNowPlayingItem
            }

            // 锁屏卡片和控制中心上那两颗，是分开的 play / pause。
            center.playCommand.isEnabled = true
            center.playCommand.addTarget { [weak self] _ in
                self?.run { await $0.resume() } ?? .noActionableNowPlayingItem
            }
            center.pauseCommand.isEnabled = true
            center.pauseCommand.addTarget { [weak self] _ in
                self?.run { await $0.pause() } ?? .noActionableNowPlayingItem
            }
            center.stopCommand.isEnabled = true
            center.stopCommand.addTarget { [weak self] _ in
                self?.run { await $0.stop() } ?? .noActionableNowPlayingItem
            }

            // 前后拖。系统给的是**秒数**，而服务端收的是**比例** ——
            // 这里做换算，长度未知时退回固定 15%（跟界面上那两颗同一个值）。
            for (command, sign) in [(center.skipForwardCommand, 1.0),
                                    (center.skipBackwardCommand, -1.0)]
            {
                command.preferredIntervals = [15]
                command.isEnabled = true
                command.addTarget { [weak self] event in
                    guard let self, let remote = target else {
                        return .noActionableNowPlayingItem
                    }
                    let seconds = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
                    let ratio: Double = if let total = remote.total, total > 0 {
                        min(seconds / total, 1)
                    } else {
                        0.15
                    }
                    Task { await remote.seek(sign * ratio) }
                    return .success
                }
            }

            // ⛔ **上一首/下一首显式关掉。** 不关的话锁屏上会出现两颗
            //    按下去什么都不发生的按钮 —— 而「按了没反应」比「没有这个按钮」
            //    坏得多：它让人以为是坏了，而不是没有。
            //    （AirPods 双击/三击发的正是这两条，所以这里不是假想情况。）
            center.nextTrackCommand.isEnabled = false
            center.previousTrackCommand.isEnabled = false
        }

        // MARK: -

        /// 捏一下：在播就停，停着就继续，**播完了就重播**。
        ///
        /// 最后那一档是故意的。播完之后 `isActive` 翻假但 `fid` 还在，
        /// 这时候捏一下最可能的意图就是「刚才那句没听清，再来一遍」——
        /// Chris 原话。让它什么都不做等于白白浪费一个已经在手上的动作。
        ///
        /// ## ⚠️ 必须先 `refresh()` 再判断，这条是承重的
        ///
        /// 这是唯一一个**要先读状态才知道该做什么**的命令（play / pause / stop
        /// 的意图是明确的，它不是）。而锁屏时本地状态**一定是旧的**：
        ///
        /// 进度轮询挂在渲染闸门上（`CCRenderGate`），锁屏就停 ——
        /// 那是省电那轮特意做的，不该为这件事推翻。于是锁屏期间服务端
        /// 播完了、或者开始了新的一段，这边完全不知道。
        ///
        /// 拿旧状态判断的后果不是「不响应」，是**做反**：
        /// 本地记着「已播完」，于是捏一下去重播 —— 而实际上它正在说新的一段，
        /// 用户得到的是「我想让它停，它反而从头开始了」。
        ///
        /// ⇒ 多一次 RPC 往返（几十毫秒，只在按键那一刻发生），
        /// 换掉一整类「按了反而更糟」。**比让轮询一直开着便宜得多** ——
        /// 后者是每 4 秒一次，前者是一天几次。
        private func toggle() -> MPRemoteCommandHandlerStatus {
            guard let remote = target else { return .noActionableNowPlayingItem }
            Task {
                await remote.refresh()
                if remote.isActive {
                    if remote.isPaused { await remote.resume() } else { await remote.pause() }
                } else if remote.canReplay {
                    await remote.replay()
                }
            }
            return .success
        }

        /// 处理器**必须立刻返回**一个状态，不能 await —— 卡在这儿系统会认为
        /// 我们没响应。所以一律「派个 Task 出去，然后报成功」。
        ///
        /// ⚠️ 代价写清楚：**这个 `.success` 报的是「收到了」，不是「做成了」。**
        /// RPC 真失败时锁屏上不会有任何提示，只有 app 里那条
        /// `CCPlaybackBar` 的错误文字看得到。这是系统 API 的形状决定的，
        /// 不是我们偷懒 —— 但别以为报了 success 就等于生效了。
        private func run(
            _ action: @escaping (CCPlaybackRemote) async -> Void
        ) -> MPRemoteCommandHandlerStatus {
            guard let remote = target else { return .noActionableNowPlayingItem }
            Task { await action(remote) }
            return .success
        }
    }

#endif
