import SwiftUI
import AppKit

/// 离屏渲染界面（假数据，不读聊天库、不调翻译接口），给开发时看排版用
@MainActor func renderPreview(_ name: String, to path: String) {
    _ = NSApplication.shared
    let model = AppModel()
    let now = Date()
    let chats = [
        Chat(id: 900001, name: "Ana García", isGroup: false, lastDate: now.addingTimeInterval(-300)),
        Chat(id: 900002, name: "张三", isGroup: false, lastDate: now.addingTimeInterval(-3600)),
        Chat(id: 900003, name: "Vecinos Calle Mayor", isGroup: true, lastDate: now.addingTimeInterval(-86400)),
        Chat(id: 900004, name: "+34 600 123 456", isGroup: false, lastDate: now.addingTimeInterval(-86400 * 3)),
        Chat(id: 900005, name: "Pedro Ruiz", isGroup: false, lastDate: now.addingTimeInterval(-86400 * 9)),
    ]
    model.chats = chats
    model.selectedChatID = 900001
    let m: [Message] = [
        Message(id: 1, chatID: 900001, isFromMe: false, sender: nil, date: now.addingTimeInterval(-86400 - 600), kind: .text,
                text: "Hola, ¿qué tal? Mañana paso a las 10 para revisar la caldera."),
        Message(id: 2, chatID: 900001, isFromMe: true, sender: nil, date: now.addingTimeInterval(-86400 - 500), kind: .text,
                text: "Perfecto, te espero. Gracias.", status: 8),
        Message(id: 3, chatID: 900001, isFromMe: false, sender: nil, date: now.addingTimeInterval(-900), kind: .audio,
                text: "Ya estoy en la puerta, podéis bajar cuando queráis.", mediaPath: "/tmp/x.opus"),
        Message(id: 4, chatID: 900001, isFromMe: false, sender: nil, date: now.addingTimeInterval(-600), kind: .text, text: "¿Vale?"),
        Message(id: 5, chatID: 900001, isFromMe: true, sender: nil, date: now.addingTimeInterval(-300), kind: .document, text: "contrato.pdf", status: 6),
    ]
    model.messages = m
    model.translations = [1: "你好，最近怎么样？我明天 10 点过来检查一下锅炉。", 3: "我已经在门口了，你们随时可以下来。", 4: "好吗？"]
    model.sentRecords = [2: SentRecord(chinese: "好的，我等你。谢谢。", language: "es")]
    model.transcripts = [3: Transcript(text: m[2].text, language: "es", seconds: 6)]
    model.previews = [900001: m[4], 900002: Message(id: 9, chatID: 900002, isFromMe: false, sender: nil, date: now, kind: .text, text: "好的，明天见")]
    model.unread = [900002: 2]
    model.hasDBAccess = true

    let size: NSSize
    let view: AnyView
    switch name {
    case "main":
        size = NSSize(width: 1100, height: 820)
        view = AnyView(ChatView())
    case "settings":
        size = NSSize(width: 720, height: 680)
        view = AnyView(SettingsView())
    case "s-perm":   size = NSSize(width: 720, height: 640); view = AnyView(SettingsPage { PermissionStatus() })
    case "s-engine": size = NSSize(width: 720, height: 900); view = AnyView(SettingsPage { EngineSection() })
    case "s-style":  size = NSSize(width: 720, height: 640); view = AnyView(SettingsPage { StyleSection() })
    case "s-voice":  size = NSSize(width: 720, height: 760); view = AnyView(SettingsPage { VoiceSection() })
    case let w where w.hasPrefix("wizard"):
        size = NSSize(width: 1000, height: 760)
        view = AnyView(SetupWizard(startStep: Int(w.dropFirst(6)) ?? 0))
    default:
        size = NSSize(width: 1000, height: 260)
        view = AnyView(ComposeView())
    }
    let host = NSHostingView(rootView: view.environmentObject(model)
        .foregroundStyle(Theme.ink).background(Theme.bg).frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    // 让 onAppear / 布局跑一下
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("ok \(path)")
}
