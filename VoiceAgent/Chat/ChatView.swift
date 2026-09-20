import LiveKitComponents
import SwiftUI

struct ChatView: View {
    /// ⚠️ **这是全 app 唯一一个该保留 `@EnvironmentObject Session` 的地方。**
    ///
    /// 它显示的就是 `session.messages`，而那个属性没有镜像可读 ——
    /// 字幕本来就得跟着消息流走。代价（跟着 Session 每条变化重算）
    /// 在这里可以接受，因为**只有打开字幕时它才在视图树上**。
    ///
    /// 其余 8 处订阅都已经拆掉了，理由见 `CCRoomSlot` 里那段 ⛔。
    @EnvironmentObject private var session: Session

    var body: some View {
        ChatScrollView(messageBuilder: message)
            .padding(.horizontal)
            .ccAnimation(.default, value: session.messages)
    }

    private func message(_ message: ReceivedMessage) -> some View {
        ZStack {
            switch message.content {
            case let .userTranscript(text), let .userInput(text):
                userTranscript(text)
            case let .agentTranscript(text):
                agentTranscript(text)
            }
        }
    }

    private func userTranscript(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 4 * .grid)
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 17))
                .padding(.horizontal, 4 * .grid)
                .padding(.vertical, 2 * .grid)
                .foregroundStyle(.fg1)
                .background(
                    RoundedRectangle(cornerRadius: .cornerRadiusLarge)
                        .fill(.bg2)
                )
        }
    }

    private func agentTranscript(_ text: String) -> some View {
        HStack {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 17))
                .padding(.vertical, 2 * .grid)
            Spacer(minLength: 4 * .grid)
        }
    }
}
