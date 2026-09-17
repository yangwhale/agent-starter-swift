import SwiftUI

/// A simple replacement for the native circular progress indicator.
///
/// ## 「减弱动态效果」下换成呼吸，而不是停转
///
/// 旋转是典型的前庭刺激，开了那个开关就不该转。但**停下来的转圈看着像卡死** ——
/// 它唯一的作用就是说明「还在跑」，静止的那一刻这个信息就没了。
///
/// 所以换成透明度呼吸：淡入淡出不属于该开关要抑制的那一类效果，
/// 而「它还在动」这件事仍然传达得到。
struct Spinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var rotation: Double = 0
    @State private var dimmed = false

    var body: some View {
        Circle()
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [.clear, .white]),
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle: .degrees(360)
                ),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(rotation))
            .opacity(dimmed ? 0.35 : 1)
            .onAppear {
                if reduceMotion {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        dimmed = true
                    }
                } else {
                    withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
            }
    }
}

#Preview {
    Spinner()
}
