import Foundation

/// 中间那块主画面**这一刻该显示什么** —— 纯判定，不碰 SwiftUI。
///
/// ## 为什么要抽出来
///
/// 这台开发机是 Linux、没有 Xcode，**写在 View 里的分支在真机跑之前没有任何
/// 人能说它对不对**（见 `Tests/README.md`）。而这里的规则有三条容易写反：
///
///   1. 没开数字人的时候**不能**显示形象静图 —— 屏幕上凭空出现一张脸，
///      会让人以为数字人已经在跑了。
///   2. 开着数字人但图还没下下来，要**退回柱子**，不能留空白。
///   3. 「在说话」优先于一切 —— 有视频就播视频，别被静图挡住。
///
/// 三条都是「某个条件下才现形」的那类：日常用永远走不到，写反了不会有人发现。
///
/// ## 为什么按 `allCases` 找角色而不是 `wants.roles.first`
///
/// `Set` 的遍历顺序每个进程都不一样。真有两个角色同时开着时，
/// `roles.first` 会**随机**给出其中一个 —— 同一次会话里甚至可能来回跳。
/// `CCAvatarWants.storageValue` 为同一个理由也走 `allCases`。
nonisolated enum CCStage: Equatable {
    /// 播数字人的视频轨。
    case video
    /// 显示这个角色的形象静图。
    case still(CCPersonaRole)
    /// 画声音柱子。
    case bars
    /// 还没连上，什么都不画。
    case idle
}

/// - Parameters:
///   - connected: 房间连上了没有。
///   - speakingWithVideo: **有视频轨**并且**这一刻在说话**。
///     两个条件合成一个传进来：拆开的话调用方很容易只判一个。
///   - wants: 客户端想开哪个角色的数字人。
///     用「想开」而不是「服务端已分配」—— 用户一按开关就该看见那张脸，
///     不用等控制面派完槽位（派槽位要几秒，那几秒盯着柱子会以为没生效）。
///   - hasImage: 这个角色的形象图在不在手上。
nonisolated func ccStage(connected: Bool,
                         speakingWithVideo: Bool,
                         wants: CCAvatarWants,
                         hasImage: (CCPersonaRole) -> Bool) -> CCStage {
    // 在说话就播视频 —— 这一条压过后面所有分支，连没连上都不用问：
    // 有帧在流本身就说明连着。
    if speakingWithVideo { return .video }
    guard connected else { return .idle }
    if let role = ccPoster(connected: connected, wants: wants, hasImage: hasImage) {
        return .still(role)
    }
    return .bars
}

/// 该不该垫一张底片，垫谁的。**跟「在不在说话」无关。**
///
/// 界面上静图是垫在视频**底下**的，不是跟视频二选一 —— 视频首帧还没到的
/// 那几百毫秒全靠它顶着。所以「有没有底片」这个问题必须能单独问，
/// 不能从 `ccStage` 的结果反推（那个结果在说话时是 `.video`，
/// 反推会得出「没有底片」，于是又出现空档）。
///
/// 两个判据跟 `ccStage` 共用同一份实现，改一处两处都变。
nonisolated func ccPoster(connected: Bool,
                          wants: CCAvatarWants,
                          hasImage: (CCPersonaRole) -> Bool) -> CCPersonaRole? {
    guard connected else { return nil }
    guard let role = CCPersonaRole.allCases.first(where: wants.contains),
          hasImage(role) else { return nil }
    return role
}
