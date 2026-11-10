import SwiftUI
import AppKit

/// 菜单 autoTrans → 设置…（⌘,）
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PermissionStatus()
                Divider()
                EngineSection()
                Divider()
                StyleSection()
                Divider()
                VoiceSection()
            }
            .padding(28)
        }
        .frame(width: 680, height: 720)
        .foregroundStyle(Theme.ink)
        .background(Theme.bg)
        .preferredColorScheme(.light)
    }
}

/// 「用什么翻译」整块：选方式 + 对应的配置。设置页和首次向导共用。
struct EngineSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("用什么翻译").font(Theme.label)
                Picker("", selection: $model.engine) {
                    ForEach(TranslationEngine.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                .font(Theme.body)
            }
            Divider()
            if model.engine == .online { OnlineSection() } else { LocalModelSection() }
        }
    }
}

// MARK: - 联网模型

struct OnlineSection: View {
    @EnvironmentObject var model: AppModel
    @State private var newKey = ""
    @State private var keyMessage: String?
    @State private var verifying = false
    @State private var modelList: [String] = []
    @State private var listError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 服务商
            VStack(alignment: .leading, spacing: 10) {
                Text("服务商").font(Theme.label)
                Picker("", selection: $model.provider) {
                    ForEach(OnlineProvider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden().font(Theme.body)
                if model.provider == .custom {
                    Text("接口地址（支持 OpenAI 兼容格式的服务，如通义千问、Kimi、智谱等）").font(Theme.small)
                    TextField("例如 https://api.example.com/v1", text: $model.customBaseURL)
                        .textFieldStyle(.roundedBorder).font(Theme.body)
                }
            }

            // API key
            VStack(alignment: .leading, spacing: 10) {
                Text("API key").font(Theme.label)
                Text(model.hasKey ? "✓ 已保存在本机" : "✗ 还没有填")
                    .font(Theme.body)
                    .foregroundStyle(model.hasKey ? Theme.accent : Theme.warn)
                Text(model.provider.keyHint).font(Theme.small).foregroundStyle(Theme.inkSoft)
                HStack {
                    SecureField(model.hasKey ? "要更换时，粘贴新的 key" : "粘贴 API key", text: $newKey)
                        .textFieldStyle(.roundedBorder).font(Theme.body)
                    Button(verifying ? "验证中…" : "验证并保存") { verifyKey() }
                        .disabled(newKey.isEmpty || verifying)
                        .font(Theme.body).controlSize(.large)
                }
                if let keyMessage { Text(keyMessage).font(Theme.small).textSelection(.enabled) }
            }

            // 模型
            VStack(alignment: .leading, spacing: 10) {
                Text("模型").font(Theme.label)
                if !modelList.isEmpty {
                    Picker("", selection: Binding(
                        get: { model.modelName },
                        set: { model.models[model.provider.rawValue] = $0 })) {
                        if !modelList.contains(model.modelName) && !model.modelName.isEmpty {
                            Text(model.modelName).tag(model.modelName)
                        }
                        if model.modelName.isEmpty { Text("请选择…").tag("") }
                        ForEach(modelList, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().font(Theme.body)
                } else {
                    TextField("模型名", text: Binding(
                        get: { model.modelName },
                        set: { model.models[model.provider.rawValue] = $0 }))
                        .textFieldStyle(.roundedBorder).font(Theme.body)
                    Text(model.hasKey ? (listError ?? "正在读取可用模型…") : "填好 key 之后，这里会列出可选的模型")
                        .font(Theme.small).foregroundStyle(Theme.inkSoft)
                }
                if model.provider == .anthropic {
                    Text("推荐 claude-opus-5-5（默认）").font(Theme.small).foregroundStyle(Theme.inkSoft)
                }
            }
        }
        .task(id: model.provider) { await loadModels() }
    }

    private func verifyKey() {
        verifying = true
        keyMessage = nil
        let p = model.provider
        Task {
            do {
                let list = try await model.verifyAndSaveKey(newKey, for: p)
                modelList = Self.chatModels(list)
                keyMessage = "✓ key 有效，已保存（可用模型 \(modelList.count) 个）"
                newKey = ""
            } catch {
                keyMessage = "✗ 验证失败：\(error.localizedDescription)"
            }
            verifying = false
        }
    }

    private func loadModels() async {
        modelList = []
        listError = nil
        guard model.hasKey else { return }
        do { modelList = Self.chatModels(try await model.availableModels(for: model.provider)) }
        catch { listError = "读取模型列表失败：\(error.localizedDescription)。可以直接手动填模型名。" }
    }

    /// OpenAI 的列表里混着语音、画图、向量等模型，翻译用不上，滤掉
    static func chatModels(_ all: [String]) -> [String] {
        let skip = ["embedding", "tts", "whisper", "dall-e", "moderation", "image", "audio",
                    "realtime", "transcribe", "search", "davinci", "babbage", "sora"]
        return all.filter { id in !skip.contains { id.lowercased().contains($0) } }
    }
}

// MARK: - 本机模型

struct LocalModelSection: View {
    @EnvironmentObject var model: AppModel
    @State private var checks: [ModelCheck] = []
    @State private var trialResult: String?
    @State private var trialRunning = false

    private let sample = "Hola Ana, mañana a las 10 paso por Calle Mayor 5 para arreglar la caldera, ¿vale?"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本机模型所在目录").font(Theme.label)
            Text(model.localModelPath.isEmpty ? "（还没有选择）" : model.localModelPath)
                .font(.system(size: 16 * Theme.scale, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            Button("选择目录…") { chooseDirectory() }
                .font(Theme.body).controlSize(.large)
            Text("需要 MLX 格式的模型文件夹（例如 Qwen2.5-7B-Instruct-4bit），里面应有 config.json、tokenizer.json 和 .safetensors 文件。")
                .font(Theme.small).foregroundStyle(Theme.inkSoft)

            // 文件检查结果：✓/✗ 符号 + 颜色，不只靠颜色
            if !checks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(checks) { c in
                        Text((c.ok ? "✓ " : "✗ ") + c.text)
                            .foregroundStyle(c.ok ? Theme.ink : Theme.warn)
                    }
                }
                .font(Theme.small)
            }

            // 真正加载模型试译一句：文件齐全不代表能用
            Button(trialRunning ? "试译中…" : "试译一句，确认能用") { runTrial() }
                .disabled(trialRunning || checks.isEmpty || checks.contains { !$0.ok })
                .font(Theme.body).controlSize(.large)
            if let trialResult {
                Text(trialResult).font(Theme.small).textSelection(.enabled)
            }
            Text("提示：本机模型运行时占用约 5 GB 内存；第一次加载要十几秒到一分钟。翻译质量比联网模型差，西班牙口语可能翻得生硬。")
                .font(Theme.small).foregroundStyle(Theme.inkSoft)
        }
        .onAppear { checks = LocalTranslator.checkDirectory(model.localModelPath) }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选这个目录"
        panel.message = "选择模型所在的文件夹（里面应有 config.json、tokenizer.json 和 .safetensors 文件）"
        if !model.localModelPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: model.localModelPath).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.localModelPath = url.path
            checks = LocalTranslator.checkDirectory(url.path)
            trialResult = nil
        }
    }

    private func runTrial() {
        trialRunning = true
        trialResult = "正在加载模型并翻译…"
        let path = model.localModelPath
        let t0 = Date()
        Task {
            do {
                let zh = try await LocalTranslator.shared.translate(sample, context: [], modelPath: path)
                trialResult = String(format: "✓ 能用（用时 %.0f 秒）\n原文：%@\n译文：%@", Date().timeIntervalSince(t0), sample, zh)
            } catch {
                trialResult = "✗ 加载或翻译失败：\(error.localizedDescription)"
            }
            trialRunning = false
        }
    }
}

/// 两项系统权限的状态（设置页顶部）
struct PermissionStatus: View {
    @EnvironmentObject var model: AppModel
    @State private var axOK = WhatsAppSender.hasPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("权限").font(Theme.label)
            Text(model.hasDBAccess ? "✓ 读取 WhatsApp 聊天记录（完全磁盘访问权限）" : "✗ 不能读取聊天记录（完全磁盘访问权限）")
                .foregroundStyle(model.hasDBAccess ? Theme.ink : Theme.warn)
            HStack(spacing: 12) {
                Text(axOK ? "✓ 在 WhatsApp 里发消息（设备控制和数据访问）" : "✗ 不能发消息（设备控制和数据访问）")
                    .foregroundStyle(axOK ? Theme.ink : Theme.warn)
                if !axOK {
                    Button("请求权限") { WhatsAppSender.requestPermission() }
                    Button("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        }
        .font(Theme.body)
        .task {
            while !Task.isCancelled {
                axOK = WhatsAppSender.hasPermission
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - 语音消息转文字（可选）

/// 设置页和首次向导共用
struct VoiceSection: View {
    @EnvironmentObject var model: AppModel
    @State private var detected: [URL] = []
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("语音消息转文字（可选）").font(Theme.label)
            Text("对方发来语音时，在这台电脑上用 Whisper large-v3 把语音转成文字，再翻译成中文。录音不上传到网上，不花钱。")
                .font(Theme.body)
            VStack(alignment: .leading, spacing: 4) {
                Text("• 需要一个约 2.9 GB 的语音模型，只下载一次。")
                Text("• 第一次使用时，系统要花 5–10 分钟优化模型（只有这一次），之后打开几秒就好。")
                Text("• 运行时占用约 3 GB 内存；一条 10 秒的语音大约 2–3 秒转完。")
                Text("• 不需要的话可以跳过，语音消息就只显示「［语音］」。以后随时可以在设置里开启。")
            }
            .font(Theme.small).foregroundStyle(Theme.inkSoft)

            // 当前状态
            if let folder = model.whisperFolder {
                Text("✓ 已开启：\(folder.path)")
                    .font(Theme.small).foregroundStyle(Theme.accent).textSelection(.enabled)
                HStack(spacing: 12) {
                    Button(testing ? "加载中…（第一次可能要几分钟）" : "检查能不能用") { test(folder) }
                        .disabled(testing)
                    Button("关闭语音转文字") { model.disableWhisper(); testResult = nil }
                }
                .font(Theme.body).controlSize(.large)
                if let testResult { Text(testResult).font(Theme.small).textSelection(.enabled) }
            } else {
                Text("✗ 还没开启").font(Theme.small).foregroundStyle(Theme.warn)

                // 方式一：本机已经有模型
                if !detected.isEmpty {
                    Text("在这台电脑上找到了已下载的模型，可以直接用：").font(Theme.small)
                    ForEach(detected, id: \.self) { url in
                        HStack {
                            Text(url.path).font(.system(size: 15 * Theme.scale, design: .monospaced))
                                .lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Button("用这个") { model.useWhisperFolder(url.path) }.font(Theme.body)
                        }
                    }
                }

                // 方式二：下载
                if let p = model.whisperDownload {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: p)
                        HStack {
                            Text(String(format: "正在下载 %.0f%%（共约 2.9 GB）", p * 100)).font(Theme.small)
                            Spacer()
                            Button("取消下载") { model.cancelWhisperDownload() }.font(Theme.small)
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        Button("下载语音模型（\(WhisperModel.sizeText)）") { model.startWhisperDownload() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                        // 方式三：自己指定
                        Button("我已经下载过，选择文件夹…") { choose() }
                    }
                    .font(Theme.body).controlSize(.large)
                    Text("下载到：\(WhisperModel.base.path)（不在 OneDrive 里）。这台电脑还剩 \(WhisperModel.gb(WhisperModel.freeSpace())) 空间。")
                        .font(Theme.small).foregroundStyle(Theme.inkSoft).textSelection(.enabled)
                }
            }
            if let m = model.whisperMessage {
                Text(m).font(Theme.small)
                    .foregroundStyle(m.hasPrefix("✗") ? Theme.warn : Theme.ink).textSelection(.enabled)
            }
        }
        .onAppear { detected = WhisperModel.detectExisting() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "用这个文件夹"
        panel.message = "选择 Whisper 模型文件夹（里面有 AudioEncoder.mlmodelc 等文件），选它的上一级也可以"
        if panel.runModal() == .OK, let url = panel.url {
            let info = WhisperModel.resolve(url.path).map(WhisperModel.folderInfo)
            model.useWhisperFolder(url.path)
            if let info, info.cloudOnly {
                model.whisperMessage = "⚠ 已使用，但这个文件夹里有 OneDrive「仅在线」的文件，第一次用时要先从云端下载，会很慢。建议在访达里右键 →「始终保留在此设备上」。"
            }
        }
    }

    private func test(_ folder: URL) {
        testing = true
        testResult = nil
        let t0 = Date()
        Task {
            do {
                try await VoiceTranscriber.shared.warmUp(folder)
                testResult = String(format: "✓ 模型能用（加载用了 %.0f 秒）", Date().timeIntervalSince(t0))
            } catch {
                testResult = "✗ 加载失败：\(error.localizedDescription)"
            }
            testing = false
        }
    }
}

// MARK: - 我的说话风格（建议回复用）

struct StyleSection: View {
    @EnvironmentObject var model: AppModel
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("我的说话风格（「建议回复」照着这个写）").font(Theme.label)
            Text("第一次点「建议回复」时，会把你最近发出的约 200 条消息发给翻译服务，总结出你的说话习惯。总结结果存在这台电脑上，可以直接改。")
                .font(Theme.small).foregroundStyle(Theme.inkSoft)
            TextEditor(text: $model.replyStyle)
                .font(Theme.small)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 180)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                .overlay(alignment: .topLeading) {
                    if model.replyStyle.isEmpty {
                        Text("（还没有总结）").font(Theme.small).foregroundStyle(Theme.placeholder).padding(12).allowsHitTesting(false)
                    }
                }
            ShortcutRecorder()
            HStack(spacing: 12) {
                Button(model.styleBusy ? "总结中…" : "根据我发过的消息重新总结") {
                    message = nil
                    Task {
                        do { try await model.summarizeStyle(); message = "✓ 已更新" }
                        catch { message = "✗ \(error.localizedDescription)" }
                    }
                }
                .disabled(model.styleBusy)
                if let message { Text(message).font(Theme.small) }
            }
            .font(Theme.body).controlSize(.large)
        }
    }
}

/// 改「建议回复」的快捷键：点「修改」，再按新的组合键
struct ShortcutRecorder: View {
    @EnvironmentObject var model: AppModel
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    // 只带 ⌘ 时不能用的键：系统和 autoTrans 自己在用
    private static let reservedCmd: Set<Character> = ["q", "w", "h", "m", "c", "v", "x", "a", "z", ",", "=", "-", "0", "+", "n", "o", "p", "s", "f"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("「建议回复」快捷键：").font(Theme.body)
                Text(recording ? "请按新的组合键…" : model.suggestShortcutText)
                    .font(Theme.f(19, .bold))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(recording ? Theme.mine : Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(recording ? Theme.accent : Theme.border, lineWidth: recording ? 2 : 1))
                Button(recording ? "取消（Esc）" : "修改") { recording ? stop() : start() }
                Button("恢复默认 ⌘/") { model.suggestKey = "/"; model.suggestMods = 1; message = "✓ 已恢复为 ⌘/" }
            }
            .font(Theme.body).controlSize(.large)
            if let message {
                Text(message).font(Theme.small).foregroundStyle(message.hasPrefix("✗") ? Theme.warn : Theme.ink)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        message = "按下想用的组合键，必须带 ⌘ 或 ⌃（比如 ⌘/、⌘J、⌃⇧R）。按 Esc 取消。"
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); message = nil; return nil }   // Esc
            let f = e.modifierFlags.intersection([.command, .shift, .option, .control])
            guard f.contains(.command) || f.contains(.control) else {
                message = "✗ 要带 ⌘ 或 ⌃，不然打字时会误触"; return nil
            }
            // 不带修饰键时的那个字符（⇧/ 也记成 /）
            guard let raw = e.characters(byApplyingModifiers: [])?.lowercased(), let ch = raw.first,
                  raw.count == 1, ch.isASCII, !ch.isWhitespace, ch.unicodeScalars.first!.value >= 33 else {
                message = "✗ 请用字母、数字或符号键"; return nil
            }
            if f == .command && Self.reservedCmd.contains(ch) {
                message = "✗ ⌘\(String(ch).uppercased()) 已经被系统或 autoTrans 占用了，换一个"; return nil
            }
            model.suggestKey = String(ch)
            model.suggestMods = (f.contains(.command) ? 1 : 0) | (f.contains(.shift) ? 2 : 0)
                | (f.contains(.option) ? 4 : 0) | (f.contains(.control) ? 8 : 0)
            message = "✓ 已改为 \(model.suggestShortcutText)"
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
