import Observation
import SwiftUI
#if os(iOS)
    import PhotosUI
    import UIKit
#endif

/// 每个房间的小图标 —— 存在本机，一个 emoji 而已。
///
/// ## emoji 为主，也能传自己的图
///
/// 方块只有 52pt，**那么小的地方 emoji 的辨识度通常比人脸照片高** ——
/// 照片缩到这个尺寸容易糊成一团色块。所以默认给 emoji，但 Chris 2026-09-18
/// 要求也能传图：有些房间就是有一张标志性的图，比照什么 emoji 都准。
///
/// 传的图**存在本机**（Application Support，不进 UserDefaults —— 那是给小配置
/// 用的，塞图片会把整个 plist 撑大、每次读写都全量反序列化）。
/// 跨设备一致要服务端下发，等「换台设备又要重设一遍」真的开始烦了再搬。
///
/// ## 没设过图标的显示名字首字母，不给通用机器人图标
///
/// 六个一模一样的机器人头，等于没有图标。首字母至少能区分。
@MainActor
@Observable
final class CCRoomIcons {
    static let shared = CCRoomIcons()

    /// 键是房间名。**整份替换而不是逐键改** ——
    /// 观察是挂在 `map` 这个属性上的，逐键改动不保证被看见。
    private(set) var map: [String: String]

    /// 传过图的房间 → 那张图。**跟 emoji 分开两份**，因为它们的取舍不同：
    /// emoji 轻、可以整份塞 UserDefaults；图片重、只能落盘，而且要能缓存。
    private(set) var images: [String: Image] = [:]

    private static let key = "cc.roomIcons"

    private init() {
        map = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        loadImagesFromDisk()
    }

    // MARK: - 自定义图片

    private static var imageDir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("cc-room-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 房间名直接当文件名是危险的（`../` 能写到别处），而且房间名里可能有
    /// 中文和空格。用哈希，**不做字符替换** —— 替换之后两个不同的房间
    /// 可能落到同一个文件上，那比报错难查得多。
    private static func fileName(for room: String) -> String {
        var h: UInt64 = 5381
        for b in Array(room.utf8) { h = h &* 33 &+ UInt64(b) }
        return String(h, radix: 36) + ".png"
    }

    private func loadImagesFromDisk() {
        guard let dir = Self.imageDir else { return }
        var next: [String: Image] = [:]
        for room in (UserDefaults.standard.stringArray(forKey: Self.key + ".images") ?? []) {
            let url = dir.appendingPathComponent(Self.fileName(for: room))
            #if os(iOS)
                if let d = try? Data(contentsOf: url), let ui = UIImage(data: d) {
                    next[room] = Image(uiImage: ui)
                }
            #endif
        }
        images = next
    }

    /// 传一张图当这个房间的方块。传 nil = 删掉，回到 emoji / 首字母。
    ///
    /// ⚠️ **落盘和内存缓存要一起更新**，而且内存那份要整份替换 ——
    /// SwiftUI 对字典逐键变更不保证发通知（跟上面 `map` 同一个原因）。
    func setImage(_ data: Data?, for room: String) {
        guard let dir = Self.imageDir else { return }
        let url = dir.appendingPathComponent(Self.fileName(for: room))
        var rooms = Set(UserDefaults.standard.stringArray(forKey: Self.key + ".images") ?? [])
        var next = images
        if let data {
            #if os(iOS)
                // 存成方形缩略图：原图可能几 MB，而这里只画 52pt。
                // 不缩的话每次进这个界面都要解一张大图。
                guard let ui = UIImage(data: data), let small = ui.ccSquareThumb(256),
                      let png = small.pngData() else { return }
                try? png.write(to: url, options: .atomic)
                next[room] = Image(uiImage: small)
                rooms.insert(room)
            #endif
        } else {
            try? FileManager.default.removeItem(at: url)
            next.removeValue(forKey: room)
            rooms.remove(room)
        }
        images = next
        UserDefaults.standard.set(Array(rooms), forKey: Self.key + ".images")
    }

    func image(for room: String) -> Image? { images[room] }

    /// 显示用的字符：设过就用设的，没设过退回名字首字母（大写）。
    func icon(for room: String) -> String {
        if let custom = map[room], !custom.isEmpty { return custom }
        return String(room.prefix(1)).uppercased()
    }

    func hasCustomIcon(_ room: String) -> Bool {
        !(map[room] ?? "").isEmpty
    }

    /// 这个房间有没有任何自定义外观（图或 emoji）。
    func hasCustomLook(_ room: String) -> Bool {
        images[room] != nil || hasCustomIcon(room)
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

    private var icons: CCRoomIcons { .shared }
    @Environment(\.dismiss) private var dismiss

    /// 分组，不是一长条。
    ///
    /// 原来只有 24 个，Chris 2026-09-18 说太少、要多几页。但**「多」不等于
    /// 「全量 emoji 键盘」** —— 那等于把选择困难原样甩回给用户。
    /// 分组的作用是把一次 200 选 1 变成先选一类、再在几十个里挑，
    /// 每一步都还在人能扫一眼看完的量级。
    ///
    /// 第一组特意叫「常用」并放了原来那 24 个：老用户上来还是熟悉的那一屏，
    /// 不会因为「变丰富了」反而找不到自己一直在用的那个。
    static let groups: [(name: String, items: [String])] = [
        ("常用", ["🐰", "🤖", "🦀", "🧠", "🐙", "🦊", "🐼", "🦉",
                "⚡️", "🔧", "📊", "🧪", "🚀", "🛰", "📡", "🗂",
                "🎙", "💡", "🔍", "🧩", "🌊", "🔥", "🌙", "⭐️"]),
        ("动物", ["🐶", "🐱", "🐭", "🐹", "🐯", "🦁", "🐮", "🐷",
                "🐸", "🐵", "🦝", "🐺", "🦄", "🐝", "🦋", "🐢",
                "🐬", "🐳", "🦈", "🐊", "🦕", "🦖", "🐧", "🦜",
                "🦚", "🦩", "🐘", "🦒", "🦔", "🐨", "🐻", "🐻‍❄️"]),
        ("表情", ["😀", "😅", "🤣", "🙂", "😉", "😍", "🤩", "🤔",
                "🤨", "😐", "🙄", "😴", "🥳", "😎", "🤓", "🧐",
                "😤", "🥺", "😱", "🤖", "👻", "💀", "👾", "🤡",
                "😺", "🙈", "🙉", "🙊", "💩", "🫠", "🫡", "🥸"]),
        ("科技", ["💻", "🖥", "⌨️", "🖱", "💾", "💿", "📀", "🧮",
                "📱", "☎️", "📞", "📟", "📠", "🔋", "🔌", "💡",
                "🔭", "🔬", "⚙️", "🛠", "⚗️", "🧲", "🧰", "🪛",
                "🛜", "📶", "🔗", "🗜", "⏱", "⏳", "🔒", "🔑"]),
        ("交通", ["🚗", "🚕", "🚌", "🚑", "🚒", "🚜", "🏎", "🛻",
                "🚲", "🛵", "🏍", "✈️", "🚀", "🛸", "🚁", "⛵️",
                "🚤", "🛥", "🚢", "🚂", "🚄", "🚇", "🛺", "🛴"]),
        ("自然", ["🌞", "🌝", "🌛", "⭐️", "🌟", "✨", "⚡️", "🔥",
                "🌈", "☁️", "🌧", "❄️", "🌊", "🌋", "🏔", "🌵",
                "🌲", "🌳", "🍀", "🌸", "🌻", "🌹", "🍁", "🌍"]),
        ("食物", ["🍎", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🥝",
                "🍅", "🥑", "🌽", "🥕", "🍞", "🧀", "🍖", "🍗",
                "🍔", "🍟", "🍕", "🌮", "🍣", "🍜", "🍚", "🍰",
                "🍩", "🍪", "☕️", "🍵", "🧋", "🍺", "🍷", "🥤"]),
        ("符号", ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍",
                "✅", "❌", "⭕️", "❗️", "❓", "💯", "🔔", "🎯",
                "🎲", "🧩", "🏆", "🥇", "🎁", "🎈", "🎉", "🗝",
                "🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "⚫️", "⚪️"]),
    ]

    @State private var groupIndex = 0
    #if os(iOS)
        @State private var pick: PhotosPickerItem?
    #endif

    private let columns = [GridItem(.adaptive(minimum: 54), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                uploadRow
                groupTabs
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Self.groups[groupIndex].items, id: \.self) { emoji in
                            emojiButton(emoji)
                        }
                    }
                    .padding()

                    Button {
                        icons.set("", for: room)
                        icons.setImage(nil, for: room)
                        dismiss()
                    } label: {
                        Text(verbatim: "恢复默认（显示首字母 \(String(room.prefix(1)).uppercased())）")
                            .font(.system(size: 14))
                    }
                    .padding(.bottom)
                }
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
        .frame(minWidth: 300, idealWidth: 320, minHeight: 440, idealHeight: 520)
    }

    // MARK: - 传自己的图

    /// 放在**最上面**，不是折在某个「更多」里。
    /// Chris 明确要这个功能，藏起来等于没做。
    @ViewBuilder
    private var uploadRow: some View {
        #if os(iOS)
            // ⚠️ **先在 body 里把值取出来，别在 PhotosPicker 的 label 闭包里读
            //    `icons`。** 那个闭包是 `@Sendable` + nonisolated 的，而 `icons`
            //    是 MainActor 隔离的 —— 在里面读它现在是 warning，
            //    Swift 6 语言模式收紧之后会变成 error。
            //
            //    同一个方法里第 `if icons.image(...)` 那处没告警，因为它在 body
            //    的 MainActor 上下文里。**区别只在「在不在闭包里」**，
            //    肉眼看几乎一样，所以这里留个记号。
            let current = icons.image(for: room)
            HStack(spacing: 10) {
                ZStack {
                    if let img = current {
                        img.resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.3)))

                PhotosPicker(selection: $pick, matching: .images, photoLibrary: .shared()) {
                    Text(verbatim: current == nil ? "用自己的图片" : "换一张")
                        .font(.system(size: 15, weight: .medium))
                }
                Spacer()
                if current != nil {
                    Button(role: .destructive) {
                        icons.setImage(nil, for: room)
                    } label: {
                        Text(verbatim: "移除").font(.system(size: 14))
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task {
                    // 拿原始字节交给 store 去缩 —— 缩图那一步要在一个地方做，
                    // 分散到调用点迟早会出现「有的缩了有的没缩」。
                    let data = try? await item.loadTransferable(type: Data.self)
                    await MainActor.run {
                        if let data { icons.setImage(data, for: room) }
                        pick = nil
                    }
                }
            }
            Divider().padding(.top, 8)
        #else
            EmptyView()
        #endif
    }

    // MARK: - 分组

    /// 横向一排分类。**不用 TabView 的 page 样式** —— 那个只能左右滑，
    /// 想直接跳到「符号」得滑七下；一排可点的标签是常数次操作。
    private var groupTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(Self.groups.enumerated()), id: \.offset) { i, g in
                    Button {
                        groupIndex = i
                    } label: {
                        Text(verbatim: g.name)
                            .font(.system(size: 13, weight: groupIndex == i ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(groupIndex == i
                                ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func emojiButton(_ emoji: String) -> some View {
        Button {
            icons.set(emoji, for: room)
            // ⚠️ 选 emoji 要把图片清掉。两者同时存在时方块只能画一个，
            //    留着另一个 = 用户以为换了、其实被另一层盖住，
            //    而且「移除图片」之后会突然冒出一个他早忘了的 emoji。
            icons.setImage(nil, for: room)
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

#if os(iOS)
    extension UIImage {
        /// 居中裁成正方形再缩到 `side`。方块本来就是方的，
        /// 不裁的话长图缩完两边全是空白。
        func ccSquareThumb(_ side: CGFloat) -> UIImage? {
            let m = min(size.width, size.height)
            let rect = CGRect(x: (size.width - m) / 2, y: (size.height - m) / 2,
                              width: m, height: m)
            guard let cg = cgImage?.cropping(to: rect) else { return nil }
            let square = UIImage(cgImage: cg, scale: scale, orientation: imageOrientation)
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                           format: fmt).image { _ in
                square.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            }
        }
    }
#endif
