import SwiftUI

/// 把「上面那个方块」和「下面那个窗口」缝成一个整体的那截**颈部**。
///
/// ## 为什么需要它
///
/// 多房间之后最容易迷路的一件事是：下面这块内容到底是谁的？六个助理长得一样，
/// 名字又在上面一排小字里。光靠「选中的方块加个高亮」不够 —— 那只说明
/// 「这个方块被选了」，没说明「下面那块是它的」。
///
/// 一截实体的颈部把两者连起来，就变成了浏览器标签页那种关系：
/// 窗口是从这个方块**长出来的**。滑动切换时颈部跟着挪到隔壁方块，
/// 「整块东西换了个主人」这件事不用文字解释。
///
/// ## 为什么不用 matchedGeometryEffect
///
/// 那个适合「同一个元素从 A 位置飞到 B 位置」。这里要画的是一个
/// **把两个不同元素缝起来的第三者**，它的形状取决于两端的相对位置，
/// 不是位移动画。用 anchor preference 拿到方块的 x，自己画一条路径更直接，
/// 也不用担心两棵子树的生命周期对不上（方块常驻，窗口内容在分页里换）。
enum CCTileConnector {
    /// 颈部这条带子有多高。
    ///
    /// 别调太大：它是「缝合线」不是「楼梯」，高了会让方块看着离窗口很远，
    /// 反而削弱「连在一起」的感觉。
    static let height: CGFloat = 10
}

/// 每个方块把自己的位置报上来，供颈部定位。
///
/// 用 `Anchor<CGRect>` 而不是 `CGRect`：anchor 是延迟解析的，
/// 在哪个坐标空间里量由读取方决定，不用两边约定同一个 `coordinateSpace` 名字。
struct CCTileAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>])
    {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 颈部本体。放在方块行和窗口之间的那条带子里。
struct CCTileNeckView: View {
    let anchors: [String: Anchor<CGRect>]
    let activeName: String
    /// 跟窗口用同一个描边色，否则接缝处会露出两种颜色。
    let stroke: Color
    /// 跟窗口用**同一个**填充。
    ///
    /// 类型是 `AnyShapeStyle` 不是 `Color`：窗口现在用的是
    /// 系统材质（这样背景图能透出来），颈部必须能收下同一个东西。
    /// 两边差一点点，接缝处就会出现一道边 —— 而那道边正好在最显眼的位置。
    let fill: AnyShapeStyle

    var body: some View {
        GeometryReader { proxy in
            if let anchor = anchors[activeName] {
                let centerX = proxy[anchor].midX
                let height = proxy.size.height
                CCTileNeckShape(centerX: centerX)
                    .fill(fill)
                    .overlay(
                        CCTileNeckShape(centerX: centerX)
                            .stroke(stroke, lineWidth: 1.5)
                            // 底边要压在窗口描边上，不然接缝处会出现一道横线。
                            // 往下挪半个线宽，让两条描边重合。
                            .offset(y: 0.75)
                            .mask(Rectangle().frame(height: height))
                    )
                    // 切换时颈部滑过去。用 spring 而不是 linear：
                    // 它模拟的是「整块东西被拖过去」，需要一点惯性感。
                    .animation(.spring(response: 0.32, dampingFraction: 0.82), value: activeName)
            }
        }
    }
}

/// 颈部的形状：上窄下宽的梯形，两肩带一点圆角。
///
/// 上窄下宽是有意的 —— 视觉上像从方块「淌下来」汇入窗口，
/// 等宽的直筒看着像一根柱子把两块东西顶开，方向感反了。
private struct CCTileNeckShape: Shape {
    var centerX: CGFloat

    /// 让 `centerX` 可动画。不实现这个的话，切换时颈部是瞬移的，
    /// 上面那个 `.animation` 完全不起作用。
    var animatableData: CGFloat {
        get { centerX }
        set { centerX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let topHalf: CGFloat = 12
        let bottomHalf: CGFloat = 24
        let height = rect.height

        var path = Path()
        path.move(to: CGPoint(x: centerX - topHalf, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: centerX - bottomHalf, y: height),
            control: CGPoint(x: centerX - topHalf, y: height * 0.75)
        )
        path.addLine(to: CGPoint(x: centerX + bottomHalf, y: height))
        path.addQuadCurve(
            to: CGPoint(x: centerX + topHalf, y: 0),
            control: CGPoint(x: centerX + topHalf, y: height * 0.75)
        )
        path.closeSubpath()
        return path
    }
}
