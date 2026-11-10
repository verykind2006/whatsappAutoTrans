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
        }
    }

    /// WhatsApp 窗口关着时的顶部提示（不挡住消息）
    private var windowClosedBanner: some View {
        HStack(spacing: 12) {
            Text("⚠ WhatsApp 窗口关着：能正常收消息，发消息时会自动打开它")
                .font(Theme.small).foregroundStyle(Theme.ink)
            Spacer()
            Button("打开 WhatsApp 窗口") { WhatsAppSender.launchWhatsApp() }
                .font(Theme.small)
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
                    Text(chat.isGroup ? "群聊" : "单聊 · 发消息翻成\(model.targetLanguage.title)")
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
            VStack(alignment: .leading, spacing: 14) {
                Text("给新号码发消息").font(Theme.title)
                Text("1. 在上面填对方的手机号（带国家码，例如 +34 600 123 456；西班牙号码可以只写 9 位）。")
                Text("2. 在下面打中文 → ⌘↩ 翻译 → 核对 → ⌘↩ 发送。")
                Text("发送时 WhatsApp 会打开和这个号码的聊天并发出消息，然后自动回到这里，左边列表里会出现这个聊天。")
                Text("如果对方没有用 WhatsApp，WhatsApp 会提示号码无效，消息不会发出。")
            }
            .font(Theme.body)
            .lineSpacing(5)
            .padding(22)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .padding(24)
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
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
            }
            .onChange(of: model.messages.last?.id) { _, last in
                if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
            .onChange(of: model.translations.count) { _, _ in
                if let last = model.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onAppear {
                if let last = model.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

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
        .font(Theme.small)
        .lineLimit(1)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Theme.bar)
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
                    Label("新消息", systemImage: "square.and.pencil")
                        .font(Theme.f(17, .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(model.composingNew ? Theme.accent : Color.white))
                        .foregroundStyle(model.composingNew ? Color.white : Theme.accent)
                        .overlay(Capsule().stroke(Theme.accent, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help("输入手机号，给新的人发消息")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Theme.bar)

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
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bar))
            .padding(.horizontal, 12).padding(.vertical, 8)

            Rectangle().fill(Theme.border).frame(height: 1)

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
                Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 1).padding(.leading, 74)
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

                content

                Text(Self.timeFmt.string(from: message.date))
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

    /// 语音：🎤 时长 + 播放按钮
    private var voiceHeader: some View {
        HStack(spacing: 10) {
            Text("🎤 语音" + durationText).font(Theme.f(16, .semibold)).foregroundStyle(Theme.inkSoft)
            if let path = message.mediaPath {
                let playing = player.playingID == message.id
                Button { player.toggle(id: message.id, path: path) } label: {
                    Label(playing ? "停止" : "播放", systemImage: playing ? "stop.fill" : "play.fill")
                        .font(Theme.f(15, .semibold))
                }
                .buttonStyle(.bordered)
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
            // 译文预览：浮在输入栏上方
            if let out = model.outgoingText {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.targetLanguage == .zh ? "将发送（可以修改）" : "译文 · \(model.targetLanguage.title)（可以直接修改）")
                            .font(Theme.f(15, .bold)).foregroundStyle(Theme.accent)
                        Spacer()
                        Button("重新翻译") { model.outgoingText = nil; model.translateDraft() }
                            .disabled(model.composeBusy)
                        Button { model.outgoingText = nil; model.backTranslation = "" } label: {
                            Label("不发了", systemImage: "xmark")
                        }
                        .disabled(model.composeBusy)
                    }
                    .font(Theme.small)
                    TextEditor(text: Binding(get: { out }, set: { model.outgoingText = $0 }))
                        .font(Theme.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 54, maxHeight: 90)
                    if !model.backTranslation.isEmpty {
                        Text("意思是：" + model.backTranslation)
                            .font(Theme.small).foregroundStyle(Theme.inkSoft)
                            .textSelection(.enabled)
                    }
                }
                .padding(10).padding(.leading, 4)
                .background(Theme.mine)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 4) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // 输入栏：语言 + 中文输入框 + 绿色按钮
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    ForEach(TargetLanguage.allCases) { lang in
                        Button(lang.title) { model.targetLanguage = lang }
                    }
                } label: {
                    Text("翻成 " + model.targetLanguage.title).font(Theme.f(16, .semibold))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("发给这个聊天时翻成哪种语言（每个聊天单独记住）")
                .padding(.bottom, 12)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.draft)
                        .font(Theme.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6).padding(.vertical, 8)
                    if model.draft.isEmpty {
                        Text("在这里打中文…（回车换行）").font(Theme.body).foregroundStyle(Theme.inkSoft)
                            .padding(.horizontal, 11).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: composeHeight)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))

                actionButton
            }

            if let e = model.composeError {
                Text("⚠ " + e).font(Theme.small).foregroundStyle(Theme.warn).textSelection(.enabled)
            } else if let s = model.composeStatus {
                Text(s).font(Theme.small).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.bar)
    }

    /// 没译文时是「翻译」，有译文时是「发送」；快捷键都是 ⌘↩
    @ViewBuilder private var actionButton: some View {
        let sending = model.outgoingText != nil
        let disabled = model.composeBusy
            || (sending ? (model.composingNew && model.newChatDigits == nil) : !hasDraft)
        let title = sending ? (model.composeBusy ? "发送中…" : "发送")
            : (model.composeBusy ? "翻译中…" : (model.targetLanguage == .zh ? "预览" : "翻译"))
        Button {
            if sending { model.sendOutgoing() } else { model.translateDraft() }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: sending ? "paperplane.fill" : "character.bubble")
                    .font(Theme.f(20, .semibold))
                Text(title).font(Theme.f(16, .bold))
                Text("⌘↩").font(Theme.f(13, .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 76 * Theme.scale, height: 76 * Theme.scale)
            .background(RoundedRectangle(cornerRadius: 12).fill(disabled ? Theme.inkSoft.opacity(0.45) : Theme.accent))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(disabled)
        .help(sending ? "发到 WhatsApp（⌘+回车）" : "翻译（⌘+回车）")
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
        VStack(alignment: .leading, spacing: 20) {
            Text("先打开并登录 WhatsApp").font(Theme.f(26, .bold))
            Text(info.title).font(Theme.f(21, .bold)).foregroundStyle(Theme.warn)
            Text(info.detail).font(Theme.body).lineSpacing(6)
            HStack(spacing: 14) {
                if let b = info.button {
                    Button(b) { WhatsAppSender.launchWhatsApp() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                }
                Button("重新检查") { model.checkWhatsApp(force: true) }
            }
            .font(Theme.body).controlSize(.large)
            Text("⏳ 每 3 秒自动检查一次").font(Theme.small).foregroundStyle(Theme.inkSoft)
        }
        .padding(40)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chatBg)
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
