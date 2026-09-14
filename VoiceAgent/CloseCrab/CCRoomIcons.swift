import SwiftUI

/// 每个房间的小图标 —— 存在本机，一个 emoji 而已。
///
/// ## 为什么先做 emoji，不做头像照片、也不先做服务端下发
///
/// - 方块只有 52pt。**那么小的地方 emoji 的辨识度反而比人脸照片高** ——
///   照片缩到这个尺寸基本是一团色块。
/// - 十几行代码就能用上。服务端下发才能跨设备一致，但那要改前端服务，
///   等「换台设备又要重设一遍」真的开始烦了再搬 —— 那时数据结构已经定好，很便宜。
///
/// ## 没设过图标的显示名字首字母，不给通用机器人图标
///
/// 六个一模一样的机器人头，等于没有图标。首字母至少能区分。
@MainActor
final class CCRoomIcons: ObservableObject {
    static let shared = CCRoomIcons()

    /// 键是房间名。用 `@Published` 整份替换而不是逐键改 ——
    /// SwiftUI 对字典的逐键变更不保证发通知。
    @Published private(set) var map: [String: String]

    private static let key = "cc.roomIcons"

    private init() {
        map = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// 显示用的字符：设过就用设的，没设过退回名字首字母（大写）。
    func icon(for room: String) -> String {
        if let custom = map[room], !custom.isEmpty { return custom }
        return String(room.prefix(1)).uppercased()
    }

    func hasCustomIcon(_ room: String) -> Bool {
        !(map[room] ?? "").isEmpty
    }

    /// 设一个图标。传空串 = 恢复默认（首字母）。
    func set(_ icon: String, for room: String) {
        var next = map
        let trimmed = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { next.removeValue(forKey: room) } else { next[room] = trimmed }
        map = next
        UserDefaults.standard.set(next, forKey: Self.key)
    }
}

/// 长按方块弹出来的图标选择器。
struct CCIconPickerSheet: View {
    let room: String

    @ObservedObject private var icons = CCRoomIcons.shared
    @Environment(\.dismiss) private var dismiss

    /// 挑过的一批，覆盖常见角色。**不做全量 emoji 键盘** ——
    /// 那等于把选择困难甩给用户，而这个决定根本不值得他想那么久。
    private let choices = [
        "🐰", "🤖", "🦀", "🧠", "🐙", "🦊", "🐼", "🦉",
        "⚡️", "🔧", "📊", "🧪", "🚀", "🛰", "📡", "🗂",
        "🎙", "💡", "🔍", "🧩", "🌊", "🔥", "🌙", "⭐️",
    ]

    private let columns = [GridItem(.adaptive(minimum: 54), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(choices, id: \.self) { emoji in
                        Button {
                            icons.set(emoji, for: room)
                            dismiss()
                        } label: {
                            Text(verbatim: emoji)
                                .font(.system(size: 30))
                                .frame(width: 54, height: 54)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(icons.map[room] == emoji ? Color.accentColor.opacity(0.25) : .clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(icons.map[room] == emoji ? Color.accentColor : .clear,
                                                      lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()

                Button {
                    icons.set("", for: room)
                    dismiss()
                } label: {
                    Text(verbatim: "恢复默认（显示首字母 \(String(room.prefix(1)).uppercased())）")
                        .font(.system(size: 14))
                }
                .padding(.bottom)
            }
            .navigationTitle(Text(verbatim: "\(room) 的图标"))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: { Text(verbatim: "完成") }
                    }
                }
        }
        // popover 要自己定尺寸 —— sheet 靠 detents，popover 靠内容固有大小。
        // 不给的话它会撑到一个很怪的宽度。
        .frame(minWidth: 300, idealWidth: 320, minHeight: 380, idealHeight: 420)
    }
}
