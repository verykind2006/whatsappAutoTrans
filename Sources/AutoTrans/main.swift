import SwiftUI
import AppKit

struct AutoTransApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("autoTrans 翻译", id: "main") {
            RootView()
                .environmentObject(model)
                .onAppear { model.start() }
        }
        .defaultSize(width: 980, height: 840)
        .commands {
            // 「autoTrans → 设置…（⌘,）」由下面的 Settings 场景自动生成，不要再手动加，否则会出现两个
            // 窗口菜单 → 窗口置顶
            // 显示 → 放大/缩小字号（快捷键实际由 AppModel 里的按键监听处理，⌘= 也算放大）
            CommandGroup(before: .toolbar) {
                Button("放大字号") { model.zoom(1) }.keyboardShortcut("+", modifiers: .command)
                Button("缩小字号") { model.zoom(-1) }.keyboardShortcut("-", modifiers: .command)
                Button("实际大小") { model.zoom(0) }.keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            CommandGroup(after: .windowArrangement) {
                Toggle("窗口置顶（浮在 WhatsApp 上面）", isOn: $model.pinned)
                    .keyboardShortcut("t", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

/// 命令行自检：autoTrans --selftest [聊天编号]
/// 读出某个聊天最近的外语消息，翻译最多 5 条并打印。不开窗口。
func runSelfTest(_ args: [String]) async -> Int32 {
    let db = WhatsAppDB()
    guard db.canOpen() else { print("✗ 打不开 WhatsApp 数据库（没有完全磁盘访问权限？）"); return 1 }
    // 自检时允许从环境变量拿 key（免得命令行程序每次都要读本机文件）
    // 环境变量可选：AT_PROVIDER（anthropic/openai/deepseek）、AT_MODEL、AT_KEY
    let env = ProcessInfo.processInfo.environment
    let provider = OnlineProvider(rawValue: env["AT_PROVIDER"] ?? "") ?? .anthropic
    guard let key = env["AT_KEY"] ?? env["ANTHROPIC_API_KEY"] ?? KeyStore.readKey(account: provider.keychainAccount) else {
        print("✗ 没有 \(provider.title) 的 API key"); return 1
    }
    guard let modelName = env["AT_MODEL"] ?? provider.defaultModel else { print("✗ 请用 AT_MODEL 指定模型"); return 1 }
    let cfg = OnlineConfig(provider: provider, baseURL: provider.defaultBaseURL, apiKey: key, model: modelName)
    do {
        let chats = try db.chats()
        print("✓ 读到 \(chats.count) 个聊天")
        let wanted = args.dropFirst(2).first.flatMap(Int.init)
        let chat = wanted.flatMap { w in chats.first { $0.id == w } }
            ?? chats.first { c in ((try? db.messages(chatID: c.id)) ?? []).contains { $0.needsTranslation } }
        guard let chat else { print("没有找到含外语消息的聊天"); return 0 }
        let msgs = try db.messages(chatID: chat.id, limit: 30)
        let targets = Array(msgs.filter(\.needsTranslation).suffix(5))
        print("✓ 聊天「\(chat.name)」\(chat.isGroup ? "（群）" : "")：\(msgs.count) 条，翻译最后 \(targets.count) 条外语消息…")
        let speaker: (Message) -> String = { m in m.isFromMe ? "我" : (chat.isGroup ? (m.sender ?? "群成员") : chat.name) }
        let t0 = Date()
        let result = try await OnlineTranslator.translate(cfg,
            chatName: chat.name, isGroup: chat.isGroup,
            transcript: msgs.filter { !$0.text.isEmpty }.map { .init(id: $0.id, speaker: speaker($0), text: $0.text) },
            targetIDs: targets.map(\.id))
        print(String(format: "✓ 用时 %.1f 秒\n", Date().timeIntervalSince(t0)))
        for m in targets {
            print("[\(speaker(m))] \(m.text)\n   → \(result[m.id] ?? "（漏翻）")\n")
        }
        return 0
    } catch {
        print("✗ \(error.localizedDescription)")
        return 1
    }
}

/// 命令行自检本机模型：autoTrans --selftest-local [模型目录]
func runLocalSelfTest(_ args: [String]) async -> Int32 {
    guard let path = args.dropFirst(2).first else { print("用法：autoTrans --selftest-local <模型目录>"); return 2 }
    for c in LocalTranslator.checkDirectory(path) { print((c.ok ? "✓ " : "✗ ") + c.text) }
    let samples = [
        "Hola Ana, mañana a las 10 paso por Calle Mayor 5 para arreglar la caldera, ¿vale?",
        "Porfa avísame cuando llegues, q no tengo batería",
        "Ya hemos firmado un contrato con el seguro, os informo en cuanto sepa algo.",
    ]
    do {
        for s in samples {
            let t0 = Date()
            let zh = try await LocalTranslator.shared.translate(s, context: [], modelPath: path)
            print(String(format: "\n[%.1f 秒] %@\n   → %@", Date().timeIntervalSince(t0), s, zh))
        }
        return 0
    } catch {
        print("✗ \(error.localizedDescription)")
        return 1
    }
}

/// 命令行自检发消息的翻译：autoTrans --selftest-out "中文"（只翻译，不发送）
func runOutgoingSelfTest(_ args: [String]) async -> Int32 {
    let chinese = args.dropFirst(2).first ?? "你好，明天上午10点我在家，你可以过来修一下热水器吗？谢谢！"
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? KeyStore.readKey(account: "anthropic-api-key") else { print("✗ 没有 Anthropic key"); return 1 }
    let cfg = OnlineConfig(provider: .anthropic, baseURL: OnlineProvider.anthropic.defaultBaseURL, apiKey: key, model: "claude-opus-5-5")
    do {
        let r = try await OnlineTranslator.translateOutgoing(cfg, chinese: chinese, to: .es, chatName: "Ana", transcript: [])
        print("中文：\(chinese)\n西语：\(r.translation)\n意思是：\(r.backTranslation)")
        return 0
    } catch { print("✗ \(error.localizedDescription)"); return 1 }
}

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--ax-open" {
    // 诊断：只在 WhatsApp 里点开某个聊天，不发消息
    do { try MainActor.assumeIsolated { try WhatsAppSender.openChat(named: CommandLine.arguments[2]) }; print("pressed") }
    catch { print("✗", error.localizedDescription) }
    exit(0)
} else if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--render" {
    // 用假数据把界面画成 PNG，看排版用：autoTrans --render main|settings|wizard0…5|compose out.png
    MainActor.assumeIsolated { renderPreview(CommandLine.arguments[2], to: CommandLine.arguments[3]) }
    exit(0)
} else if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--ax-buttons" {
    MainActor.assumeIsolated { WhatsAppSender.dumpButtons() }
    exit(0)
} else if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--ax-dump" {
    WhatsAppSender.dump()
    exit(0)
} else if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--selftest-out" {
    let sema = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task { code = await runOutgoingSelfTest(CommandLine.arguments); sema.signal() }
    sema.wait()
    exit(code)
} else if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--selftest-suggest" {
    // autoTrans --selftest-suggest ["要点"]：用一段编的对话试一次「建议回复」（会调一次 API）
    let sema = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? KeyStore.readKey(account: "anthropic-api-key") else {
            print("✗ 没有 Anthropic key"); code = 1; sema.signal(); return
        }
        let cfg = OnlineConfig(provider: .anthropic, baseURL: OnlineProvider.anthropic.defaultBaseURL, apiKey: key, model: "claude-opus-5-5")
        let lines = [
            OnlineTranslator.Line(id: 1, speaker: "Ana", text: "Hola! Vi vuestro anuncio de las bolsas de cuero. ¿Tenéis la marrón grande?"),
            OnlineTranslator.Line(id: 2, speaker: "我", text: "Hola Ana! Sí, nos queda alguna 😊"),
            OnlineTranslator.Line(id: 3, speaker: "Ana", text: "Genial. ¿Cuánto cuesta y podéis enviarla a Valencia esta semana?"),
        ]
        let hint = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
        let t0 = Date()
        do {
            let list = try await OnlineTranslator.suggestReplies(cfg, chatName: "Ana", isGroup: false, transcript: lines,
                                                                 style: "", hint: hint, to: .es)
            print(String(format: "用时 %.1f 秒", Date().timeIntervalSince(t0)))
            for (i, x) in list.enumerated() { print("\(i + 1). [\(x.note)] \(x.chinese)\n   → \(x.reply)") }
        } catch { print("✗ \(error.localizedDescription)"); code = 1 }
        sema.signal()
    }
    sema.wait()
    exit(code)
} else if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--selftest-voice" {
    // autoTrans --selftest-voice <语音文件> [模型目录]：本机 Whisper 转文字
    let sema = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task {
        let a = CommandLine.arguments
        let folder = (a.count > 3 ? WhisperModel.resolve(a[3]) : nil) ?? WhisperModel.detectExisting().first
        if let folder {
            print("模型：\(folder.path)")
            do {
                let t0 = Date()
                try await VoiceTranscriber.shared.warmUp(folder)
                print(String(format: "加载 %.1f 秒", Date().timeIntervalSince(t0)))
                let t1 = Date()
                let t = try await VoiceTranscriber.shared.transcribe(a[2], modelFolder: folder)
                print(String(format: "转写 %.1f 秒（语音 %.1f 秒）", Date().timeIntervalSince(t1), t.seconds ?? 0))
                print("语言：\(t.language ?? "?")\n文字：\(t.text)")
            } catch { print("✗ \(error.localizedDescription)"); code = 1 }
        } else { print("✗ 没找到模型目录"); code = 2 }
        sema.signal()
    }
    sema.wait()
    exit(code)
} else if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--selftest-local" {
    let sema = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task { code = await runLocalSelfTest(CommandLine.arguments); sema.signal() }
    sema.wait()
    exit(code)
} else if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--selftest" {
    let sema = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task { code = await runSelfTest(CommandLine.arguments); sema.signal() }
    sema.wait()
    exit(code)
} else {
    AutoTransApp.main()
}
