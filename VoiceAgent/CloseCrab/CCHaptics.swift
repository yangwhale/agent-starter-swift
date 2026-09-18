#if os(iOS)
    import UIKit
#endif

/// 触觉反馈。**按意思命名，不按强度命名。**
///
/// ## 为什么要有
///
/// 这个 app 的手势全落在方块上：单击切房间、双击静音、长按换图标。
/// 而这三个动作的实际使用场景是**在地铁上、在走路、在开车**，
/// 手指按下去的那一刻眼睛常常不在屏幕上。
///
/// 没有震动的时候，「按中了没有」只能靠回头看一眼。有了之后不用看 ——
/// 这是 (Not Boring) Camera 那套拟物里唯一能单独摘出来用的东西：
/// 那些巨大的物理按钮和阻尼滚轮对我们不合适，但「按下去手上有回应」这条是通用的。
///
/// ## 为什么按意思命名
///
/// 写成 `CCHaptics.medium()` 的话，调用点看不出这一下代表什么，
/// 以后想统一调整「静音」的手感就得全局搜 `.medium` 再一个个判断。
/// 写成 `CCHaptics.mute()`，改一处就够了。
///
/// ## 生成器要留着不要现建
///
/// `UIImpactFeedbackGenerator` 第一次用之前要唤醒 Taptic Engine，现建现用的话
/// 第一下会明显迟半拍。Apple 的文档写法就是长期持有 + `prepare()`。
/// 反正这几个对象很轻。
@MainActor
enum CCHaptics {
    // MARK: - 语义入口

    /// 把话筒切给另一个房间。**最轻的一档** ——
    /// 这是这个 app 里最频繁的动作，重了会烦。
    static func switchRoom() {
        #if os(iOS)
            guard enabled else { return }
            selection.selectionChanged()
            selection.prepare()
        #endif
    }

    /// 静音 / 取消静音。比切房间重一档：
    /// **它改变的是「听不听得见」这种有后果的状态**，值得一记实的。
    static func toggleMute() {
        #if os(iOS)
            guard enabled else { return }
            medium.impactOccurred()
            medium.prepare()
        #endif
    }

    /// 双击一块牌子，给这个角色开 / 关 Avatar。跟静音同一档 ——
    /// 它改的也是「看不看得见」这种有后果的状态，而且**后果要几秒才看得见**
    /// （服务端要分配、要建会话、要出第一帧）。这段空窗里手上这一记
    /// 是唯一的「收到了」。
    static func toggleAvatar() {
        #if os(iOS)
            guard enabled else { return }
            medium.impactOccurred()
            medium.prepare()
        #endif
    }

    /// 长按弹出图标选择器。软的一下，表示「有东西要出来了」而不是「完成了」。
    static func reveal() {
        #if os(iOS)
            guard enabled else { return }
            soft.impactOccurred()
            soft.prepare()
        #endif
    }

    /// 这一下没生效（比如双击一个还没连上的方块）。
    ///
    /// **这条很重要：不给反馈和「给了但没生效」在手上是一样的。**
    /// 界面上那个方块本来就是灰的、点了也不会亮，如果手上也完全没动静，
    /// 用户只会以为自己没点准，于是再点一次。
    static func refuse() {
        #if os(iOS)
            guard enabled else { return }
            notice.notificationOccurred(.warning)
            notice.prepare()
        #endif
    }

    /// 预热。进主界面时叫一次，第一下手势就不会迟。
    static func warmUp() {
        #if os(iOS)
            guard enabled else { return }
            selection.prepare()
            medium.prepare()
            soft.prepare()
        #endif
    }

    // MARK: -

    #if os(iOS)
        /// 直接读 `CCStore` 而不是 `CloseCrabConfig.shared`。
        ///
        /// 震动是**副作用**不是渲染：没有任何视图需要因为这个开关变了而重绘，
        /// 走 ObservableObject 只会平白多一条订阅关系。
        private static var enabled: Bool { CCStore.haptics }

        private static let selection = UISelectionFeedbackGenerator()
        private static let medium = UIImpactFeedbackGenerator(style: .medium)
        private static let soft = UIImpactFeedbackGenerator(style: .soft)
        private static let notice = UINotificationFeedbackGenerator()
    #endif
}
