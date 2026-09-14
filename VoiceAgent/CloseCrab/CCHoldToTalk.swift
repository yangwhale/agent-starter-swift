import LiveKit
import SwiftUI

/// 「按住这里说话」—— 盖在中间那片本来什么都干不了的空白上。
///
/// ## 它不是对讲机
///
/// 这是**直播房间**：按下去就是开麦，声音一边说一边流过去；松手就是闭麦。
/// 没有「录一段 → 发送」这个动作，所以界面上**不许出现「发送」字样，
/// 也不许有录音时长** —— 那会让人以为松手之前对方听不见，于是说完还要等一下。
///
/// ## 为什么用 DragGesture 而不是 onLongPressGesture
///
/// `onLongPressGesture` 的回调语义是「按够时长触发一次」+「按压状态变化」，
/// 想拿到干净的「按下→松开」两端其实很别扭，而且它自带一个最短时长，
/// 手快的时候会整个不触发 —— 表现是「我明明按了，怎么没开麦」。
///
/// `DragGesture(minimumDistance: 0)` 的 `onChanged` 在手指落下那一刻就来，
/// `onEnded` 在抬起那一刻来，正好是我们要的两端，而且**零延迟**。
/// 手指在区域里滑动也不会中断，这对一块占半屏的区域很重要。
struct CCHoldToTalkArea: View {
    @EnvironmentObject private var localMedia: LocalMedia
    @EnvironmentObject private var mic: CCMicPolicy

    var body: some View {
        ZStack {
            // 透明命中层：整块区域都能按。`contentShape` 不能省 ——
            // 纯透明的 Color 在 SwiftUI 里默认不接收点击。
            Color.clear
                .contentShape(Rectangle())

            hint
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in mic.beginHold(isMicrophoneEnabled: localMedia.isMicrophoneEnabled) }
                .onEnded { _ in mic.endHold() }
        )
        .animation(.easeOut(duration: 0.15), value: mic.isHolding)
        #if os(iOS)
            // 开麦那一下给个震动。看不见的状态变化必须有别的通道告诉人，
            // 否则你只能靠「说完发现没人回」来发现自己没按住。
            .sensoryFeedback(.impact(weight: .medium), trigger: mic.isHolding)
        #endif
    }

    @ViewBuilder
    private var hint: some View {
        if localMedia.isMicrophoneEnabled, !mic.isHolding {
            // 已经手动常开麦了 —— 这块区域此刻没有作用，就别假装能按。
            pill(text: "麦克风常开中", systemImage: "microphone.fill",
                 tint: .green, border: .green.opacity(0.5), filled: true)
        } else if mic.isHolding {
            pill(text: "麦克风开着，说吧", systemImage: "waveform",
                 tint: .green, border: .green, filled: true)
        } else {
            pill(text: "按住这里说话", systemImage: "mic.slash.fill",
                 tint: .secondary, border: .secondary.opacity(0.35), filled: false)
        }
    }

    private func pill(text: String, systemImage: String,
                      tint: Color, border: Color, filled: Bool) -> some View
    {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(verbatim: text)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(filled ? tint.opacity(0.12) : Color.clear)
                .overlay(Capsule().strokeBorder(border, style: StrokeStyle(
                    lineWidth: filled ? 1.5 : 1,
                    dash: filled ? [] : [5, 4]
                )))
        )
        // 松手之后提示淡下去，不抢镜；按住时完全不透明。
        .opacity(mic.isHolding ? 1 : 0.85)
        .scaleEffect(mic.isHolding ? 1.04 : 1)
    }
}
