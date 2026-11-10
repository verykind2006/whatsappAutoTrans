import SwiftUI
import AppKit
import AVFoundation

// 参考 WhatsApp 桌面版的浅色风格，但字更大、对比更高（用户有老花眼）
enum Theme {
    static let bg = Color(hex: 0xFFFFFF)          // 一般底色（设置页、向导）
    static let bar = Color(hex: 0xF0F2F5)         // 顶栏、输入栏：浅灰
    static let chatBg = Color(hex: 0xEFEAE2)      // 聊天区：米色底
    static let ink = Color(hex: 0x111B21)         // 正文：近黑
    static let inkSoft = Color(hex: 0x3B4A54)     // 次要文字：深灰蓝（白底上对比约 9:1）
    static let mine = Color(hex: 0xD9FDD3)        // 我发的：浅绿气泡
    static let theirs = Color.white               // 对方发的：白气泡
    static let border = Color(hex: 0xC9D1D6)      // 分隔线
    static let accent = Color(hex: 0x00705A)      // 深绿（白字在上面对比约 6:1）
    static let selected = Color(hex: 0xE3E8EB)    // 列表选中行
    static let placeholder = Color(hex: 0x8A979F) // 输入框里的占位提示：浅灰，和真正打的字区分开（用户 2026-11-10 要求）
    static let warn = Color(hex: 0x9E1A0D)        // 深红

    /// 字号缩放（⌘+ / ⌘- 调，AppModel.fontScale 同步过来）
    nonisolated(unsafe) static var scale: CGFloat = 1
    static func f(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size * scale, weight: weight) }

    static var body: Font { f(19) }
    static var small: Font { f(16) }
    static var label: Font { f(16, .semibold) }
    static var title: Font { f(21, .bold) }
    static var time: Font { f(15, .medium) }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if !model.setupDone || !model.hasDBAccess { SetupWizard() }
            // 窗口关着不挡：WhatsApp 仍在线、照样收消息，只在顶部提示
            else if model.waState == .notRunning || model.waState == .notLoggedIn { WhatsAppGate() }
            else { ChatView() }
        }
        .id(model.fontScale)   // 改字号后整个界面重画
        .foregroundStyle(Theme.ink)
        .background(Theme.bg)
        .preferredColorScheme(.light)
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - 头像：圆形，名字首字；号码用人形图标，群用多人图标

struct Avatar: View {
    let name: String
    let isGroup: Bool
    var size: CGFloat = 48

    // 柔和的底色 + 深色字，颜色只是装饰，不承载信息
    private static let palette: [UInt32] = [0xD7E8FF, 0xFFE2C6, 0xDDF3D8, 0xF4DAF2, 0xFFF0B8, 0xD5F0F0, 0xE6E0FF]

    var body: some View {
        let s = size * Theme.scale
        let first = name.first.map(String.init) ?? "?"
        let isNumber = name.hasPrefix("+") || first.allSatisfy(\.isNumber)
        let color = Self.palette[abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % Self.palette.count]
        ZStack {
            Circle().fill(Color(hex: color))
            if isGroup {
                Image(systemName: "person.3.fill").font(.system(size: s * 0.36))
            } else if isNumber {
                Image(systemName: "person.fill").font(.system(size: s * 0.44))
            } else {
                Text(first.uppercased()).font(.system(size: s * 0.44, weight: .semibold))
            }
        }
        .foregroundStyle(Theme.inkSoft)
        .frame(width: s, height: s)
    }
}

// MARK: - 主界面

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    // 两条可拖动的分隔线：左栏宽度、输入框高度（记在本机）
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 300
    @AppStorage("composeHeight") private var composeHeight: Double = 76
    @State private var dragBase: Double?
    @State private var dropTargeted = false
    @State private var atBottom = true
    @State private var unseen = 0

    var body: some View {
        HStack(spacing: 0) {
            ChatSidebar()
                .frame(width: sidebarWidth)
            DragHandle(vertical: true) { dx in
                if dragBase == nil { dragBase = sidebarWidth }
                sidebarWidth = min(600, max(200, dragBase! + dx))
            } onEnd: { dragBase = nil }
            VStack(spacing: 0) {
                if model.waState == .noWindow { windowClosedBanner }
                header
                Rectangle().fill(Theme.border).frame(height: 1)
                messageList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.chatBg)
                if model.selectedChat != nil || model.composingNew {
                    // 往上拖：输入框变高
                    DragHandle(vertical: false) { dy in
                        if dragBase == nil { dragBase = composeHeight }
                        composeHeight = min(400, max(60, dragBase! - dy))
                    } onEnd: { dragBase = nil }
                    ComposeView()
                }
                statusBar
            }
            // 把文件拖到右边：放进「待发送」
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard model.selectedChat != nil, !model.composingNew else { return false }
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.addFiles([url]) } }
                    }
                }
                return true
            }
            .overlay {
                if dropTargeted, let chat = model.selectedChat, !model.composingNew {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(Theme.mine.opacity(0.92))
                        RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        VStack(spacing: 10) {
                            Image(systemName: "paperclip").font(.system(size: 40 * Theme.scale, weight: .semibold))
                            Text("松开，准备发给「\(chat.name)」").font(Theme.f(24, .bold))
                            Text("发之前还能再确认一次").font(Theme.body)
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(16)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// WhatsApp 窗口关着时的顶部提示（不挡住消息）
    private var windowClosedBanner: some View {
        HStack(spacing: 12) {
            Text("⚠ WhatsApp 窗口关着：能正常收消息，发消息时会自动打开它")
                .font(Theme.small).foregroundStyle(Theme.ink)
            Spacer()
            Button("打开 WhatsApp 窗口") { WhatsAppSender.launchWhatsApp() }.appButton()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(hex: 0xFFF3C4))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xC9A227)).frame(height: 1) }
    }

    @ViewBuilder private var header: some View {
        if model.composingNew {
            NewChatHeader()
        } else if let chat = model.selectedChat {
            HStack(spacing: 12) {
                Avatar(name: chat.name, isGroup: chat.isGroup, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.name).font(Theme.title).lineLimit(1)
                    Text(chat.isGroup ? "群聊" : "单聊")
                        .font(Theme.small).foregroundStyle(Theme.inkSoft)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.bar)
        } else {
            Text("请在左边选一个聊天")
                .font(Theme.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 18)
                .background(Theme.bar)
        }
    }

    @ViewBuilder private var messageList: some View {
        if model.composingNew {
            Card("给新号码发消息", subtitle: "如果对方没有用 WhatsApp，WhatsApp 会提示号码无效，消息不会发出。") {
                NumberedSteps(steps: [
                    "在上面填对方的手机号（带国家码，例如 +34 600 123 456；西班牙号码可以只写 9 位）",
                    "在下面打中文 → ⌘↩ 翻译 → 核对 → ⌘↩ 发送",
                    "WhatsApp 会打开和这个号码的聊天并发出消息，然后自动回到这里，左边列表里会出现这个聊天",
                ])
            }
            .frame(maxWidth: 640)
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            existingMessages
        }
    }

    private var existingMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { i, m in
                        // 日期分隔条：今天 / 昨天 / 11月8日 星期六
                        if i == 0 || !Calendar.current.isDate(model.messages[i - 1].date, inSameDayAs: m.date) {
                            DayDivider(date: m.date).padding(.vertical, 8)
                        }
                        MessageRow(message: m,
                                   speaker: model.selectedChat.map { model.speakerName(m, in: $0) } ?? "",
                                   isGroup: model.selectedChat?.isGroup ?? false,
                                   voice: voiceState(m),
                                   translation: model.translations[m.id],
                                   sent: model.sentRecords[m.id],
                                   isPending: model.pending.contains(m.id))
                        .id(m.id)
                    }
                    // 底部标记：看得见它 = 停在最底下
                    Color.clear.frame(height: 1).id(Self.bottomID)
                        .onAppear { atBottom = true; unseen = 0 }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
            }
            // 回到底部：往上翻了才出现；翻看旧消息时来了新消息，箭头上显示条数
            .overlay(alignment: .bottomTrailing) {
                if !atBottom && !model.messages.isEmpty {
                    Button {
                        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                        unseen = 0
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 20 * Theme.scale, weight: .bold))
                                .foregroundStyle(Theme.inkSoft)
                                .frame(width: 46 * Theme.scale, height: 46 * Theme.scale)
                                .background(Circle().fill(Color.white))
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                            if unseen > 0 {
                                Text("\(unseen)")
                                    .font(Theme.f(13, .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
                                    .background(Capsule().fill(Theme.accent))
                                    .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .help(unseen > 0 ? "回到底部（有 \(unseen) 条新消息）⌘↓" : "回到底部 ⌘↓")
                    .padding(.trailing, 22).padding(.bottom, 16)
                }
            }
            .onChange(of: model.messages.last?.id) { _, last in
                guard last != nil else { return }
                // 停在底部才自动跟到最新；正在往上翻看旧消息就别打断，只在箭头上记数
                if atBottom { withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
                else { unseen += 1 }
            }
            .onChange(of: model.translations.count) { _, _ in
                if atBottom { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: model.selectedChatID) { _, _ in
                // 换聊天时「最后一条」也会变，别把它算成新消息：放到下一轮再清零、跳到底
                DispatchQueue.main.async { unseen = 0; proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    private static let bottomID = "autoTrans-bottom"

    private func voiceState(_ m: Message) -> VoiceState {
        guard m.kind == .audio else { return .none }
        if m.mediaPath == nil { return .notDownloaded }
        if !m.text.isEmpty { return .done(model.transcripts[m.id]?.seconds) }
        if model.whisperFolder == nil { return .off }
        if model.transcribeFailed.contains(m.id) { return .failed }
        return .working
    }

    private var statusBar: some View {
        HStack {
            if let e = model.errorText {
                Text("⚠ " + e).foregroundStyle(Theme.warn)
            } else if !model.status.isEmpty {
                Text("⏳ " + model.status).foregroundStyle(Theme.accent)
            } else {
                Text("✓ 已是最新").foregroundStyle(Theme.inkSoft)
            }
            Spacer()
            Text("翻译：" + (model.engine == .online ? "\(model.provider.title) · \(model.modelName)" : "本机模型"))
                .foregroundStyle(Theme.inkSoft)
        }
        .font(Theme.caption)
        .lineLimit(1)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Theme.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// 聊天区里的日期条
struct DayDivider: View {
    let date: Date
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE"; return f
    }()

    var body: some View {
        let cal = Calendar.current
        let text = cal.isDateInToday(date) ? "今天" : cal.isDateInYesterday(date) ? "昨天" : Self.fmt.string(from: date)
        Text(text)
            .font(Theme.time)
            .foregroundStyle(Theme.inkSoft)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(Color.white))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - 左边：聊天列表

struct ChatSidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""

    private static let todayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日"; return f }()
    private func when(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? Self.todayFmt.string(from: d)
            : Calendar.current.isDateInYesterday(d) ? "昨天" : Self.dayFmt.string(from: d)
    }

    private var filtered: [Chat] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.chats }
        let qd = q.filter(\.isNumber)
        return model.chats.filter {
            $0.name.localizedCaseInsensitiveContains(q) || (!qd.isEmpty && $0.name.filter(\.isNumber).contains(qd))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：标题 + 新消息
            HStack {
                Text("聊天").font(Theme.f(24, .bold))
                Spacer()
                Button { model.startNewChat() } label: {
                    GhostLabel(icon: "square.and.pencil") { Text("新消息") }
                        .background(RoundedRectangle(cornerRadius: 7).fill(model.composingNew ? Theme.accentBg : .clear))
                }
                .buttonStyle(.plain)
                .help("输入手机号，给新的人发消息")
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 12)

            // 搜索
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkSoft)
                TextField("搜索聊天", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.inkSoft).help("清空")
                }
            }
            .font(Theme.f(17))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
            .padding(.horizontal, 12).padding(.bottom, 10)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { c in row(c) }
                    if filtered.isEmpty {
                        Text("没有找到「\(search)」").font(Theme.small).foregroundStyle(Theme.inkSoft).padding(20)
                    }
                }
            }
        }
        .background(Color.white)
    }

    private func row(_ c: Chat) -> some View {
        let selected = c.id == model.selectedChatID
        let newCount = model.unread[c.id] ?? 0
        return Button { model.selectedChatID = c.id } label: {
            HStack(spacing: 12) {
                Avatar(name: c.name, isGroup: c.isGroup)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(c.name)
                            .font(Theme.f(18, newCount > 0 || selected ? .bold : .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(when(c.lastDate))
                            .font(Theme.time)
                            .foregroundStyle(newCount > 0 ? Theme.accent : Theme.inkSoft)
                    }
                    HStack {
                        Text(preview(c))
                            .font(Theme.f(16, newCount > 0 ? .semibold : .regular))
                            .foregroundStyle(newCount > 0 ? Theme.ink : Theme.inkSoft)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        // 新消息：深绿圆角标 + 数字（不只靠颜色）
                        if newCount > 0 {
                            Text("\(newCount)")
                                .font(Theme.f(14, .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 24)
                                .background(Capsule().fill(Theme.accent))
                                .help("\(newCount) 条新消息")
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 选中：灰底 + 左侧深绿竖条（不只靠颜色）
            .background(selected ? Theme.selected : Color.white)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Theme.accent).frame(width: 4) }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline.opacity(0.7)).frame(height: 1).padding(.leading, 74)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 第二行：最后一条消息。外语有译文就显示中文；经 autoTrans 发出的显示中文原文
    private func preview(_ c: Chat) -> String {
        guard let m = model.previews[c.id] else { return "" }
        var body: String
        if let sent = model.sentRecords[m.id] { body = sent.chinese }
        else if let zh = model.translations[m.id] { body = zh }
        else if let t = model.transcripts[m.id] { body = t.text }
        else { body = m.text }
        let label: String?
        switch m.kind {
        case .image: label = "［图片］"
        case .video: label = "［视频］"
        case .audio: label = "［语音］"
        case .document: label = "［文件］"
        default: label = nil
        }
        if let label { body = body.isEmpty ? label : label + body }
        body = body.replacingOccurrences(of: "\n", with: " ")
        return (m.isFromMe ? "我：" : "") + body
    }
}

// MARK: - 一条消息（气泡）

enum VoiceState: Equatable {
    case none, notDownloaded, off, working, failed
    case done(Double?)
}

/// 播放语音（同一时间只放一条）
@MainActor final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()
    @Published var playingID: Int?
    private var player: AVAudioPlayer?

    func toggle(id: Int, path: String) {
        if playingID == id { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path)); return   // 放不了就交给系统
        }
        p.delegate = self
        p.play()
        player = p
        playingID = id
    }

    func stop() { player?.stop(); player = nil; playingID = nil }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playingID = nil }
    }
}

struct MessageRow: View {
    let message: Message
    let speaker: String
    let isGroup: Bool
    var voice: VoiceState = .none
    @ObservedObject private var player = VoicePlayer.shared
    let translation: String?
    let sent: SentRecord?
    let isPending: Bool

    private static let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    private var kindLabel: String? {
        switch message.kind {
        case .image: return "［图片］"
        case .video: return "［视频］"
        case .audio: return "［语音］"
        case .document: return "［文件］"
        case .other: return "［其他消息］"
        case .text, .link: return nil
        }
    }

    // 群里不同人的名字用不同的深色（都够深，白底上看得清；名字本身就是区分，不只靠颜色）
    private static let senderColors: [UInt32] = [0x0B5E8E, 0x8A3B12, 0x5B2C83, 0x006B4F, 0x9C1F5C, 0x5A5A00, 0x1F4E9C]
    private var senderColor: Color {
        Color(hex: Self.senderColors[abs(speaker.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % Self.senderColors.count])
    }

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 6) {
                if isGroup && !message.isFromMe {
                    Text(speaker).font(Theme.f(16, .bold)).foregroundStyle(senderColor)
                }

                if message.kind == .image, let path = message.mediaPath, let img = ImageCache.load(path) {
                    // 图片：显示缩略图，点一下用「预览」打开原图
                    Image(nsImage: img)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 300, maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        .help("点一下查看原图")
                }
                if message.kind == .image, message.mediaPath == nil {
                    Text("［图片］还没下载，在 WhatsApp 里点开这张图后，这里就会显示")
                        .font(Theme.small).foregroundStyle(Theme.inkSoft)
                }

                if message.kind == .audio { voiceHeader }
                if message.kind == .document || message.kind == .video { fileRow }

                content

                HStack(spacing: 8) {
                    Text(Self.timeFmt.string(from: message.date))
                    if message.isFromMe { receiptMark }
                }
                .font(Theme.time).foregroundStyle(Theme.inkSoft)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .lineSpacing(5)
            .textSelection(.enabled)
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 6)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 10).fill(message.isFromMe ? Theme.mine : Theme.theirs))
            .shadow(color: .black.opacity(0.12), radius: 0.8, y: 1)
            .frame(maxWidth: 560, alignment: message.isFromMe ? .trailing : .leading)
            if !message.isFromMe { Spacer(minLength: 70) }
        }
    }

    /// 我发的消息：勾 + 文字（不只靠颜色）。已读用深蓝，WhatsApp 的浅蓝在浅绿气泡上看不清
    @ViewBuilder private var receiptMark: some View {
        switch message.receipt {
        case .pending:
            Label("发送中", systemImage: "clock").labelStyle(ReceiptLabelStyle())
        case .sent:
            Label("已发出", systemImage: "checkmark").labelStyle(ReceiptLabelStyle())
        case .delivered:
            Label("已送达", systemImage: "checkmark").labelStyle(ReceiptLabelStyle(double: true))
        case .read:
            Label("已读", systemImage: "checkmark").labelStyle(ReceiptLabelStyle(double: true))
                .foregroundStyle(Color(hex: 0x0B5E8E))
                .fontWeight(.semibold)
        }
    }

    /// 文件 / 视频：「打开」「在访达中显示」。WhatsApp 存的文件名是一串乱码，
    /// 所以先拷一份成原来的名字（放临时文件夹），再打开它
    @ViewBuilder private var fileRow: some View {
        if let path = message.mediaPath {
            HStack(spacing: 10) {
                Button { FileOpener.open(path, name: message.text, id: message.id, reveal: false) } label: {
                    Label("打开", systemImage: "doc.text.magnifyingglass")
                }
                Button { FileOpener.open(path, name: message.text, id: message.id, reveal: true) } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
            }
            .buttonStyle(.plain)
            .labelStyle(SmallActionLabelStyle())
        } else {
            Text("还没下载：在 WhatsApp 里点开这个文件，这里就能打开")
                .font(Theme.small).foregroundStyle(Theme.inkSoft)
        }
    }

    /// 语音：🎤 时长 + 播放按钮
    private var voiceHeader: some View {
        HStack(spacing: 10) {
            Text("🎤 语音" + durationText).font(Theme.f(16, .semibold)).foregroundStyle(Theme.inkSoft)
            if let path = message.mediaPath {
                let playing = player.playingID == message.id
                Button { player.toggle(id: message.id, path: path) } label: {
                    Label(playing ? "停止" : "播放", systemImage: playing ? "stop.fill" : "play.fill")
                        .font(Theme.f(15, .semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accentBg))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var durationText: String {
        guard case .done(let s?) = voice else { return "" }
        let t = Int(s.rounded())
        return String(format: " %d:%02d", t / 60, t % 60)
    }

    @ViewBuilder private var content: some View {
        if message.kind == .audio && message.text.isEmpty {
            switch voice {
            case .notDownloaded:
                Text("还没下载：在 WhatsApp 里点开播放一下，这里就会转成文字").font(Theme.small).foregroundStyle(Theme.inkSoft)
            case .off:
                Text("在「设置 → 语音消息转文字」里开启后，会自动转成文字再翻译").font(Theme.small).foregroundStyle(Theme.inkSoft)
            case .failed:
                Text("✗ 没能转成文字（可能太短或听不清）").font(Theme.small).foregroundStyle(Theme.warn)
            default:
                Text("正在转文字…").font(Theme.body).foregroundStyle(Theme.accent)
            }
        } else if let kindLabel, message.text.isEmpty {
            if message.kind != .image { Text(kindLabel).font(Theme.body).foregroundStyle(Theme.inkSoft) }
        } else if let sent, sent.language != TargetLanguage.zh.rawValue {
            // 经 autoTrans 发出的：用户写的中文是主体，下面是实际发出去的外语
            Text(sent.chinese).font(Theme.body)
            QuoteBlock(label: "已发送（\(TargetLanguage(rawValue: sent.language)?.title ?? "外语")）", text: message.text)
        } else if message.needsTranslation {
            // 先给中文，再给原文
            if let translation {
                Text(translation).font(Theme.body)
            } else if isPending {
                Text("翻译中…").font(Theme.body).foregroundStyle(Theme.accent)
            } else {
                Text("（还没翻译）").font(Theme.body).foregroundStyle(Theme.inkSoft)
            }
            QuoteBlock(label: message.kind == .audio ? "原文（语音识别）" : "原文",
                       text: (message.kind == .audio ? "" : (kindLabel ?? "")) + message.text)
        } else {
            Text((message.kind == .audio ? "" : (kindLabel ?? "")) + message.text).font(Theme.body)
        }
    }
}

/// 气泡里的「原文 / 已发送」小块：左边一条深绿竖线 + 标签，像引用
struct QuoteBlock: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.f(14, .bold)).foregroundStyle(Theme.accent)
            Text(text).font(Theme.small).foregroundStyle(Theme.inkSoft)
        }
        .padding(.leading, 10).padding(.vertical, 5).padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.045))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 图片读一次就记住，滚动时不反复读硬盘
@MainActor enum ImageCache {
    private static var store: [String: NSImage] = [:]
    static func load(_ path: String) -> NSImage? {
        if let i = store[path] { return i }
        guard let i = NSImage(contentsOfFile: path) else { return nil }
        store[path] = i
        return i
    }
}

/// 窗口置顶：浮在 WhatsApp 上面
enum WindowPin {
    @MainActor static func apply(_ on: Bool) {
        for w in NSApp.windows where w.canBecomeMain {
            w.level = on ? .floating : .normal
        }
    }
}

// MARK: - 底部：写中文、翻译、发送

struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("composeHeight") private var composeHeight: Double = 76

    private var hasDraft: Bool { !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 待发送的文件
            if !model.pendingFiles.isEmpty { filesPanel }

            // 建议回复：点一条就放进输入框
            if !model.suggestions.isEmpty { suggestionPanel }

            // 译文预览：浮在输入栏上方
            if let out = model.outgoingText {
                ComposePanel(title: model.targetLanguage == .zh ? "将发送（可以修改）" : "译文 · \(model.targetLanguage.title)（可以直接修改）",
                             icon: "character.bubble") {
                    Button("重新翻译") { model.outgoingText = nil; model.translateDraft() }
                        .appButton().disabled(model.composeBusy)
                    Button { model.outgoingText = nil; model.backTranslation = "" } label: {
                        Label("不发了  Esc", systemImage: "xmark")
                    }
                    .appButton()
                    .keyboardShortcut(.cancelAction)   // Esc
                    .disabled(model.composeBusy)
                } content: {
                    TextEditor(text: Binding(get: { out }, set: { model.outgoingText = $0 }))
                        .font(Theme.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 54, maxHeight: 90)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mine))
                    if !model.backTranslation.isEmpty {
                        Text("意思是：" + model.backTranslation)
                            .font(Theme.caption).foregroundStyle(Theme.inkSoft)
                            .textSelection(.enabled)
                    }
                }
            }

            // 输入卡片：上面写中文，下面一行工具（无边框）+ 右下角发送按钮，合成一整块
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.draft)
                        .font(Theme.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8).padding(.top, 10)
                    if model.draft.isEmpty {
                        Text("在这里打中文…（回车换行）\n也可以只写要点，再点「建议回复」").font(Theme.body).foregroundStyle(Theme.placeholder)
                            .padding(.horizontal, 13).padding(.top, 10)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: max(composeHeight, 60 * Theme.scale))

                HStack(spacing: 4) {
                    Menu {
                        ForEach(TargetLanguage.allCases) { lang in
                            Button(lang.title) { model.targetLanguage = lang }
                        }
                    } label: {
                        GhostLabel(icon: "globe", chevron: true) {
                            Text("翻成 ").foregroundStyle(Theme.inkSoft) + Text(model.targetLanguage.title)
                        }
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("发给这个聊天时翻成哪种语言（每个聊天单独记住）")

                    Button { model.suggestReplies() } label: {
                        GhostLabel(icon: "lightbulb", hint: model.suggestBusy ? nil : model.suggestShortcutText) {
                            Text(model.suggestBusy ? "想回复中…" : "建议回复")
                        }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(model.suggestShortcut)
                    .disabled(model.suggestBusy || model.composeBusy)
                    .help("根据对话、按你的说话风格起草 3 条回复（\(model.suggestShortcutText)，可在设置里改）。输入框里先写几个要点，会按要点来写。")

                    Button { pickFiles() } label: {
                        GhostLabel(icon: "paperclip") { Text("附件") }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.composingNew || model.composeBusy)
                    .help("选文件发送（也可以直接把文件拖进窗口）")

                    Spacer(minLength: 10)

                    if model.composeError == nil, let s = model.composeStatus {
                        Text(s).font(Theme.f(16, .medium)).foregroundStyle(Theme.accent)
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.trailing, 6)
                    }
                    actionButton
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 10) }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))

            if let e = model.composeError {
                Text("⚠ " + e).font(Theme.small).foregroundStyle(Theme.warn).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.bar)
    }

    private var filesPanel: some View {
        ComposePanel(title: "要发给「\(model.selectedChat?.name ?? "")」的文件（\(model.pendingFiles.count) 个）", icon: "paperclip") {
            Button { model.pendingFiles = [] } label: { Label("不发了  Esc", systemImage: "xmark") }
                .appButton()
                .keyboardShortcut(model.outgoingText == nil ? .cancelAction : nil)
        } content: {
            ForEach(model.pendingFiles, id: \.self) { url in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().frame(width: 28 * Theme.scale, height: 28 * Theme.scale)
                    Text(url.lastPathComponent).font(Theme.body).lineLimit(1)
                    Text(Self.sizeText(url)).font(Theme.small).foregroundStyle(Theme.inkSoft)
                    Spacer()
                    Button { model.pendingFiles.removeAll { $0 == url } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(Theme.inkSoft).help("去掉这个")
                }
            }
            Text("按 ⌘↩ 或右边的「发文件」。WhatsApp 会短暂切到前面，发完自动回来。")
                .font(Theme.caption).foregroundStyle(Theme.inkSoft)
        }
    }

    static func sizeText(_ url: URL) -> String {
        let b = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "发送这些"
        if panel.runModal() == .OK { model.addFiles(panel.urls) }
    }

    private var suggestionPanel: some View {
        ComposePanel(title: "建议回复 · 点一条放进输入框，可以再改", icon: "lightbulb") {
            Button("换一批") { model.suggestReplies() }.appButton().disabled(model.suggestBusy)
            Button { model.suggestions = [] } label: { Label("关闭  Esc", systemImage: "xmark") }
                .appButton()
                // 译文框或待发文件也开着时，Esc 先给它们
                .keyboardShortcut(model.outgoingText == nil && model.pendingFiles.isEmpty ? .cancelAction : nil)
        } content: {
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { i, sug in
                Button { model.useSuggestion(sug) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1)").font(Theme.f(15, .bold)).foregroundStyle(.white)
                                .frame(width: 24 * Theme.scale, height: 24 * Theme.scale)
                                .background(Circle().fill(Theme.accent))
                            Text(sug.chinese).font(Theme.body).foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.leading)
                        }
                        if sug.reply != sug.chinese {
                            Text(sug.reply).font(Theme.small).foregroundStyle(Theme.inkSoft)
                                .multilineTextAlignment(.leading).padding(.leading, 32 * Theme.scale)
                        }
                        if !sug.note.isEmpty {
                            Text("思路：" + sug.note).font(Theme.f(14)).foregroundStyle(Theme.inkSoft)
                                .padding(.leading, 32 * Theme.scale)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("用这条")
            }
        }
        .frame(maxHeight: 360)
    }

    /// 没译文时是「翻译」，有译文时是「发送」；快捷键都是 ⌘↩
    /// 现在按 ⌘↩ 该不该有反应（每次现场算，不能用渲染时记下的值：快捷键会拿着旧值）
    private var actionDisabled: Bool {
        let files = !model.pendingFiles.isEmpty
        let sending = files || model.outgoingText != nil
        return model.composeBusy
            || (files ? false : (sending ? (model.composingNew && model.newChatDigits == nil) : !hasDraft))
    }

    private func performAction() {
        guard !actionDisabled else { return }
        // 有待发的文件先发文件；文字（如果也有译文）下次再按一次 ⌘↩
        if !model.pendingFiles.isEmpty { model.sendFiles() }
        else if model.outgoingText != nil { model.sendOutgoing() } else { model.translateDraft() }
    }

    @ViewBuilder private var actionButton: some View {
        let files = !model.pendingFiles.isEmpty
        let sending = files || model.outgoingText != nil
        let disabled = actionDisabled
        let title = sending ? (model.composeBusy ? "发送中…" : (files ? "发文件" : "发送"))
            : (model.composeBusy ? "翻译中…" : (model.targetLanguage == .zh ? "预览" : "翻译"))
        // 不用 .disabled：系统会把按钮调淡，字看不清；能不能按在 performAction 里现场判断
        Button { performAction() } label: {
            HStack(spacing: 8) {
                Image(systemName: sending ? "paperplane.fill" : "character.bubble")
                Text(title)
                Text("⌘↩").font(Theme.f(14, .semibold)).opacity(disabled ? 1 : 0.85)
            }
            .font(Theme.f(17, .semibold))
            .foregroundStyle(disabled ? Theme.inkSoft : .white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(disabled ? Theme.canvas : Theme.accent))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .help(files ? "把文件发到 WhatsApp（⌘+回车）" : sending ? "发到 WhatsApp（⌘+回车）" : "翻译（⌘+回车）")
    }
}

/// 「新消息」页顶部：填手机号
struct NewChatHeader: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Avatar(name: "+", isGroup: false, size: 44)
                Text("新消息").font(Theme.title)
                Spacer()
                Button("取消") { model.cancelNewChat() }.font(Theme.body).controlSize(.large)
            }
            HStack(spacing: 10) {
                Text("手机号：").font(Theme.label)
                TextField("例如 +34 600 123 456", text: $model.newChatPhone)
                    .textFieldStyle(.roundedBorder).font(Theme.body)
                    .focused($focused)
            }
            if !model.newChatPhone.trimmingCharacters(in: .whitespaces).isEmpty {
                if let d = model.newChatDigits {
                    Text("✓ 将发给 +\(d)").font(Theme.small).foregroundStyle(Theme.accent)
                } else {
                    Text("✗ 号码不完整：请带国家码（如 +34、+86），西班牙号码可以只写 9 位")
                        .font(Theme.small).foregroundStyle(Theme.warn)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.bar)
        .onAppear { focused = true }
    }
}

/// WhatsApp 没打开 / 没登录时停在这一页，好了自动进入
struct WhatsAppGate: View {
    @EnvironmentObject var model: AppModel

    private var info: (title: String, detail: String, button: String?) {
        switch model.waState {
        case .notRunning where !WhatsAppSender.isInstalled:
            return ("✗ 这台电脑上没有 WhatsApp",
                    "autoTrans 要配合 WhatsApp 桌面版使用。请先在 App Store 安装 WhatsApp，用手机扫码登录，然后再打开 autoTrans。", nil)
        case .notRunning:
            return ("✗ WhatsApp 没有打开",
                    "autoTrans 是贴在 WhatsApp 旁边用的。请先打开 WhatsApp。", "打开 WhatsApp")
        case .noWindow:
            return ("✗ WhatsApp 的窗口关着",
                    "WhatsApp 在运行，但窗口没有打开。请点一下程序坞里的 WhatsApp 图标，把窗口打开。", "打开 WhatsApp 窗口")
        default:
            return ("✗ WhatsApp 还没登录",
                    "在 WhatsApp 窗口里看不到聊天列表，多半停在「扫码登录」页面。\n请用手机打开 WhatsApp → 设置 → 已关联的设备 → 关联新设备，扫电脑上的二维码。登录完成、聊天列表出现后，这里会自动进入。", "切到 WhatsApp")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "先打开并登录 WhatsApp", subtitle: "autoTrans 贴在 WhatsApp 旁边用，WhatsApp 准备好后这里会自动进入。")
            Card(String(info.title.dropFirst(2))) {
                StatusBadge(ok: false, text: "未就绪")
            } content: {
                Text(info.detail).font(Theme.text).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                CardDivider()
                HStack(spacing: 10) {
                    if let b = info.button {
                        Button(b) { WhatsAppSender.launchWhatsApp() }.appButton(.primary)
                    }
                    Button("重新检查") { model.checkWhatsApp(force: true) }.appButton()
                    Spacer()
                    Text("⏳ 每 3 秒自动检查一次").font(Theme.caption).foregroundStyle(Theme.inkSoft)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

/// 可拖动的分隔线：平时是一条细线，鼠标移上去变粗变绿、光标变成左右/上下箭头
struct DragHandle: View {
    let vertical: Bool                      // true = 竖线（左右拖）
    let onDrag: (CGFloat) -> Void           // 拖动的累计位移
    let onEnd: () -> Void
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Theme.accent : Theme.border)
            .frame(width: vertical ? (hovering ? 3 : 1) : nil, height: vertical ? nil : (hovering ? 3 : 1))
            .overlay(
                Color.clear
                    .frame(width: vertical ? 12 : nil, height: vertical ? nil : 12)
                    .contentShape(Rectangle())
                    .onHover { h in
                        hovering = h
                        if h { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in onDrag(vertical ? v.translation.width : v.translation.height) }
                        .onEnded { _ in onEnd() })
            )
            .help(vertical ? "拖动可以调整左边聊天列表的宽度" : "往上拖可以把输入框拉高")
    }
}

/// 无边框的工具按钮：绿色图标 + 深色字，鼠标移上去才出现浅灰底；快捷键用小字跟在后面
struct GhostLabel<Content: View>: View {
    let icon: String
    var hint: String? = nil
    var chevron = false
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
            content.foregroundStyle(Theme.ink)
            if let hint {
                Text(hint).font(Theme.f(14, .medium)).foregroundStyle(Theme.inkSoft)
            }
            if chevron {
                Image(systemName: "chevron.down").font(Theme.f(11, .bold)).foregroundStyle(Theme.inkSoft)
            }
        }
        .font(Theme.f(16, .semibold))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover && enabled ? Theme.canvas : .clear))
        .opacity(enabled ? 1 : 0.5)
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hover = $0 }
    }
}

/// 输入栏上方浮出的面板（译文、建议回复、待发文件）：白卡片，标题行 + 分割线 + 内容
struct ComposePanel<Actions: View, Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                Text(title).font(Theme.f(17, .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 8)
                actions
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            CardDivider()
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}


/// 勾的样式：一个勾 / 两个勾叠在一起，后面跟文字
private struct ReceiptLabelStyle: LabelStyle {
    var double = false
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                configuration.icon
                if double { configuration.icon.offset(x: 5 * Theme.scale) }
            }
            .font(Theme.f(13, .bold))
            .padding(.trailing, double ? 5 * Theme.scale : 0)
            configuration.title
        }
        .help("WhatsApp 显示的发送状态")
    }
}


/// 气泡里的小按钮：浅绿底 + 深绿字 + 图标（和语音的「播放」一样）
private struct SmallActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon; configuration.title }
            .font(Theme.f(15, .semibold)).foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Capsule().fill(Theme.accentBg))
            .contentShape(Capsule())
    }
}

/// 把 WhatsApp 里的文件拷成原名再打开 / 在访达中显示。不动 WhatsApp 自己的文件
enum FileOpener {
    static func open(_ path: String, name: String, id: Int, reveal: Bool) {
        let src = URL(fileURLWithPath: path)
        let ext = src.pathExtension
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if base.isEmpty { base = "文件" }
        if !ext.isEmpty, (base as NSString).pathExtension.lowercased() != ext.lowercased() { base += "." + ext }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoTrans-files/\(id)", isDirectory: true)
        let dst = dir.appendingPathComponent(base)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dst.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? fm.copyItem(at: src, to: dst)) == nil {
                // 拷不了就直接用原文件
                show(src, reveal); return
            }
        }
        show(dst, reveal)
    }

    private static func show(_ url: URL, _ reveal: Bool) {
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
    }
}
