import LiveKitComponents
import SwiftUI

/// A multiplatform view that shows the chat input text field and send button.
struct ChatInputView: View {
    /// 只用来**发一条消息**（一个动作，不读任何状态），所以不订阅 ——
    /// `@EnvironmentObject` 会让这个输入框跟着 Session 的每条变化重算。
    @Environment(CCRoomSlot.self) private var slot

    @FocusState.Binding var keyboardFocus: Bool
    @State private var messageText = ""

    /// 输入框最宽多少。**一行文字超过约 512pt 就开始难读**，
    /// 眼睛回扫找下一行起点的距离太长 —— 这是个排版上限，不是设备上限。
    ///
    /// ## 为什么不再按 size class 分档
    ///
    /// 原来是 `horizontalSizeClass == .regular ? 512 : 368`。问题不在于
    /// size class 过时（它在分屏和可变窗口下是会跟着变的），而在于
    /// **拿一个只有两档的信号去驱动一个连续的量**：
    /// 窗口从 400 拖到 900 的过程中宽度是平滑变化的，输入框却只会在
    /// 某个阈值上「啪」地跳一下，跳之前还会有一段明显留白。
    ///
    /// WWDC26 把「iPhone app 可以被自由缩放」列为要适配的新常态，
    /// 这种二值跳变正是那个场景下最显眼的破绽。
    ///
    /// 改成只留上限：容器比它窄时 `maxWidth` 自然让位，跟着容器连续收缩；
    /// 比它宽时封顶。**少一个分支，行为反而更对。**
    private let maxLineWidth: CGFloat = 128 * .grid

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            textField()
            sendButton()
        }
        .frame(minHeight: 12 * .grid)
        .frame(maxWidth: maxLineWidth)
        #if !os(visionOS)
            .background(.bg2)
        #endif
            .clipShape(RoundedRectangle(cornerRadius: 6 * .grid))
            .safeAreaPadding(.horizontal, 4 * .grid)
            .safeAreaPadding(.bottom, 4 * .grid)
    }

    @ViewBuilder
    private func textField() -> some View {
        TextField("message.placeholder", text: $messageText, axis: .vertical)
        #if os(iOS)
            .focused($keyboardFocus)
        #endif
        #if os(visionOS)
        .textFieldStyle(.roundedBorder)
        .hoverEffectDisabled()
        #else
        .textFieldStyle(.plain)
        #endif
        .lineLimit(3)
        .submitLabel(.send)
        .onSubmit {
            // Will be called on macOS/Simulator with hardware keyboard
            Task {
                await sendMessage()
            }
        }
        .onChange(of: messageText.last?.isNewline ?? false) { _, forceSubmit in
            // onSubmit won't be called by the submit key when using a software keyboard with a .vertical TextField
            if forceSubmit {
                Task {
                    await sendMessage()
                }
            }
        }
        #if !os(visionOS)
        .foregroundStyle(.fg1)
        #endif
        .padding()
    }

    @ViewBuilder
    private func sendButton() -> some View {
        AsyncButton(action: sendMessage) {
            Image(systemName: "arrow.up")
                .frame(width: 8 * .grid, height: 8 * .grid)
        }
        #if os(iOS)
        .padding([.bottom, .trailing], 3 * .grid)
        #else
        .padding([.bottom, .trailing], 2 * .grid)
        #endif
        .disabled(messageText.isEmpty)
        #if os(visionOS)
            .buttonStyle(.plain)
        #else
            .buttonStyle(RoundButtonStyle())
        #endif
    }

    private func sendMessage() async {
        guard !messageText.isEmpty else { return }
        let text = messageText
        messageText = ""
        keyboardFocus = false
        await slot.session.send(text: text)
    }
}
