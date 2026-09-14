import LiveKit
import SwiftUI

/// 房间抽屉：随时打开、随时换人。
///
/// 为什么不是「登录时选一次」：一个 bot 一个常驻房间，切房间＝换一个助理说话，
/// 这是**会话中途最常做的事**，不是启动参数。原来那个放在连接按钮上面的选择器
/// 一连上就够不着了，等于连完就锁死在一个房间里。
///
/// 切换的做法是挂断再连（`end()` → `start()`），不是重建 `Session`：
/// SDK 的 `Session.tokenOptions` 是 `let`，本来就换不了；而
/// `CloseCrabTokenSource` 每次 `fetch` 都现读 `CCStore.room`，
/// 所以「改选择 → 重连」自然就连到新房间，一个 `Session` 用到底。
struct CCRoomListView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var rooms: CCRooms
    @ObservedObject private var config = CloseCrabConfig.shared
    @ObservedObject private var directory = CCRoomDirectory.shared

    @Environment(\.dismiss) private var dismiss
    @State private var switchingTo: String?
    @State private var settingsPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(directory.rooms) { room in
                        row(room)
                    }
                } header: {
                    Text(verbatim: "聊天室")
                } footer: {
                    footer()
                }
            }
            .refreshable { await directory.refresh() }
            // 每次打开抽屉都重拉一次。名单是服务端说了算的，缓存只是为了
            // 界面别空着 —— 拉一次的成本远低于「显示了一个已经下架的 bot」。
            .task { await directory.refresh() }
            .navigationTitle(Text(verbatim: "去哪个房间"))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { settingsPresented = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .disabled(switchingTo != nil)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: { Text(verbatim: "完成") }
                            .disabled(switchingTo != nil)
                    }
                }
                .sheet(isPresented: $settingsPresented) {
                    CloseCrabSettingsView()
                }
        }
    }

    // MARK: - 行

    /// 一行 = 两个独立的点击区，对应两个不同的意思：
    ///
    ///   左边的勾    这个房间**在不在线**（连着、听得见它说话）。可以勾好几个。
    ///   行的其余部分 把**话筒**切给它。同一时刻只有一个。
    ///
    /// **外层刻意不是 Button。** SwiftUI 的 List 里 Button 套 Button，点子按钮
    /// 经常连外层一起触发 —— 症状是勾一下在线，顺手把话筒也切过去了。
    /// 改成裸 HStack + 两个各自的手势，边界就清楚了。
    private func row(_ room: CCRoom) -> some View {
        let isOnline = config.onlineRooms.contains(room.name)
        let isActive = room.name == config.room
        let locked = switchingTo != nil

        return HStack(spacing: 12) {
            Button {
                config.toggleOnline(room.name)
            } label: {
                Image(systemName: isOnline ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    // 当前说话的那个勾不掉（见 CloseCrabConfig.toggleOnline），
                    // 所以画成灰的，明说「这个你动不了」而不是点了没反应。
                    .foregroundStyle(isActive ? .secondary : (isOnline ? Color.accentColor : .secondary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(locked || isActive)

            statusDot(room)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: room.name)
                    .font(.system(size: 17, weight: isActive ? .semibold : .regular))
                Text(verbatim: status(room))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if switchingTo == room.name {
                ProgressView()
                    #if !os(macOS)
                        .controlSize(.small)
                    #endif
            } else if isActive {
                // 话筒图标，不是对勾 —— 左边那个勾已经是「在线」的意思了，
                // 两处都画对勾的话没人分得出这一行到底在说哪件事。
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !locked { select(room) } }
        // 切换过程中把整张表锁上。连着按两个房间会让 end/start 互相打架，
        // 症状是连上了但进的是上一个房间 —— 看起来像「点错了」。
        .opacity(locked ? 0.5 : 1)
    }

    private func statusDot(_ room: CCRoom) -> some View {
        Circle()
            .fill(dotColor(room))
            .frame(width: 8, height: 8)
    }

    private func dotColor(_ room: CCRoom) -> Color {
        // nil ＝ 服务端没查到 SFU，是「不知道」不是「离线」，
        // 所以给灰色而不是红色 —— 别把查询失败画成故障。
        guard let ready = room.ready, let online = room.online else { return .gray.opacity(0.35) }
        if ready { return .green }
        if online { return .orange }
        return .gray
    }

    private func status(_ room: CCRoom) -> String {
        guard let ready = room.ready, let online = room.online else { return "状态未知" }
        if ready {
            if let n = room.participants, n > 0 { return "在岗 · 里面还有 \(n) 个人" }
            return "在岗"
        }
        if online { return "房间在，助理不在岗" }
        return "离线"
    }

    @ViewBuilder
    private func footer() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = directory.lastError {
                // 拉取失败时列表还在（用的是缓存）。不说一声的话，
                // 「旧名单」和「新名单」长得一模一样。
                Text(verbatim: "列表没刷新成功，下面是上次拿到的：\(error)")
                    .foregroundStyle(.orange)
            } else {
                Text(verbatim: "左边的勾 = 这个房间在线，听得见它说话，可以勾好几个。点行 = 把话筒切给它，同一时刻只有一个（🎤 标着的那个）。")
                Text(verbatim: "⚠️ 勾选目前只是记下来，还没接上连接层 —— 勾了也暂时不会真的多连一个房间。")
                    .foregroundStyle(.orange)
                Text(verbatim: "名单由服务端的 ALLOWED_ROOMS 决定，加了 bot 这里会自动多出来。下拉可以手动刷新。")
            }
        }
    }

    // MARK: -

    private func select(_ room: CCRoom) {
        guard switchingTo == nil else { return }
        guard room.name != config.room else {
            dismiss()
            return
        }

        // 多房间之后切换是**纯本地**的：房间本来就连着，只是把话筒挪过去。
        // 以前这里要 end() → start() 整个重连，等一两秒；现在是瞬间的。
        // 没连着时 activate 也只是改选择，等用户点连接。
        rooms.activate(room.name)
        dismiss()
    }
}
