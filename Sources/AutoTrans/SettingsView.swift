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
