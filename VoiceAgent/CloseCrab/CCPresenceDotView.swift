import SwiftUI

/// 头像右下角的在线状态小圆点 —— Google Chat 那种。规则在 `CCPresenceDot`。
///
/// 颜色取 Google 的状态色（Chat / Material 通行值），浅色深色同一套：
/// 这是**信号色**，要求两种模式下一眼认得出是同一个意思，跟 `ccSpeaking` 同一个理由。
///
/// 外面套一圈底色描边，跟 Chat 一样 —— 点压在头像边角上时，
/// 没有这圈它会跟头像图案糊在一起。
struct CCPresenceDotView: View {
    let dot: CCPresenceDot
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.bg1, lineWidth: max(1.5, size / 6)))
            // 黄点（正在连）轻轻呼吸一下 —— 「还在动」跟「卡住了」要看得出区别。
            .opacity(dot == .connecting && breathing ? 0.45 : 1)
            .ccAnimation(dot == .connecting ? .easeInOut(duration: 0.8).repeatForever() : nil, value: breathing)
            .onAppear { breathing = true }
            .accessibilityHidden(true)   // 文字由所在的方块/行统一念，见 `CCPresenceDot.spoken`
    }

    @State private var breathing = false

    private var color: Color {
        switch dot {
        case .off: Color(hex: 0x9AA0A6)        // 灰
        case .retrying: Color(hex: 0xD93025)   // 红
        case .connecting: Color(hex: 0xF9AB00) // 黄
        case .degraded: Color(hex: 0xE37400)   // 橙
        case .online: Color(hex: 0x1E8E3E)     // 绿
        }
    }
}
