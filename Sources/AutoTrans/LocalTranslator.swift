import Foundation
import Darwin
import MLXLLM
import MLXLMCommon

/// 翻译方式：默认联网模型（Claude 等）；也可切到本机模型（不花钱、不联网，但质量差一些）
enum TranslationEngine: String, CaseIterable, Identifiable {
    case online, local
    var id: String { rawValue }
    var title: String {
        switch self {
        case .online: return "联网模型（效果最好，按用量付费）"
        case .local: return "本机模型（不联网，不花钱）"
        }
    }
}

/// 本机模型目录的检查结果，一项一行，给用户看
struct ModelCheck: Identifiable {
    let id = UUID()
    let ok: Bool
    let text: String
}

/// 用 MLX 在本机跑 qwen 之类的模型做翻译（做法照搬 vInput 项目的 MLXTranslator）
actor LocalTranslator {
    static let shared = LocalTranslator()

    private var container: ModelContainer?
    private var loadedPath: String?

    // MARK: 校验目录

    /// 只看文件，不加载模型（快）。返回每一项的检查结果。
    static func checkDirectory(_ path: String) -> [ModelCheck] {
        var out: [ModelCheck] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if path.isEmpty { return [ModelCheck(ok: false, text: "还没有选择模型目录")] }
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return [ModelCheck(ok: false, text: "目录不存在")]
        }
        out.append(ModelCheck(ok: true, text: "目录存在"))

        let cfgURL = URL(fileURLWithPath: path).appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: cfgURL),
           let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let type = cfg["model_type"] as? String ?? "未知"
            out.append(ModelCheck(ok: true, text: "config.json 正常（模型类型：\(type)）"))
            if let q = cfg["quantization"] as? [String: Any], let bits = q["bits"] {
                out.append(ModelCheck(ok: true, text: "已量化：\(bits) 位（MLX 格式）"))
            }
        } else {
            out.append(ModelCheck(ok: false, text: "缺少 config.json 或内容看不懂"))
        }

        for f in ["tokenizer.json", "tokenizer_config.json"] {
            let ok = fm.fileExists(atPath: path + "/" + f)
            out.append(ModelCheck(ok: ok, text: ok ? "\(f) 存在" : "缺少 \(f)"))
        }

        let files = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        let weights = files.filter { $0.hasSuffix(".safetensors") }
        if weights.isEmpty {
            out.append(ModelCheck(ok: false, text: "没有找到模型权重文件（.safetensors）"))
        } else {
            var total: Int64 = 0
            var cloudOnly: [String] = []
            for w in weights {
                var st = stat()
                if stat(path + "/" + w, &st) == 0 {
                    total += Int64(st.st_size)
                    // OneDrive「仅在线」的占位文件：看着在，其实内容没下载到本机
                    if st.st_flags & 0x4000_0000 != 0 { cloudOnly.append(w) }
                }
            }
            let gb = String(format: "%.1f", Double(total) / 1_073_741_824)
            out.append(ModelCheck(ok: true, text: "权重文件 \(weights.count) 个，共 \(gb) GB"))
            if !cloudOnly.isEmpty {
                out.append(ModelCheck(ok: false, text: "有文件还在云盘（iCloud、OneDrive 等）里没下载到本机：\(cloudOnly.joined(separator: "、"))。请在访达里右键这个文件夹 →「始终保留在此设备上」"))
            }
        }
        return out
    }

    // MARK: 加载与翻译

    private func ensureLoaded(_ path: String) async throws -> ModelContainer {
        if let container, loadedPath == path { return container }
        container = nil
        let c = try await loadModelContainer(directory: URL(fileURLWithPath: path))
        container = c
        loadedPath = path
        return c
    }

    func isLoaded(_ path: String) -> Bool { container != nil && loadedPath == path }

    /// 切回 Claude 时释放模型，把几 GB 内存还给系统
    func unload() { container = nil; loadedPath = nil }

    private func generate(_ prompt: String, maxTokens: Int, modelPath: String) async throws -> String {
        let container = try await ensureLoaded(modelPath)
        var p = GenerateParameters()
        p.temperature = 0
        p.maxTokens = maxTokens
        let session = ChatSession(container, generateParameters: p)
        var out = ""
        for try await chunk in session.streamResponse(to: prompt) { out += chunk }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 发出去的消息：中文 → 目标语言，再直译回中文供核对（小模型分两次做更稳）
    func translateOutgoing(_ chinese: String, to lang: TargetLanguage, context: [String],
                           modelPath: String) async throws -> OnlineTranslator.Outgoing {
        let budget = max(256, chinese.count * 4 + 64)
        let tr = try await generate("""
        把【中文消息】翻成\(lang.promptName)，要通过 WhatsApp 发给对方。
        规则：礼貌、口语、自然；\(lang == .es ? "用西班牙本地说法，不用拉美说法；" : "")人名、地名、门牌号、金额、日期保持原样；不添加原文没有的意思；只输出译文本身，不要解释、不要引号。

        【前文，只帮助理解】
        \(context.suffix(6).joined(separator: "\n"))

        【中文消息】
        \(chinese)
        """, maxTokens: budget, modelPath: modelPath)
        let back = try await generate("""
        把下面这段话逐句直译成简体中文，只输出译文：
        \(tr)
        """, maxTokens: budget, modelPath: modelPath)
        return .init(translation: tr, backTranslation: back)
    }

    /// 翻译一条消息。context：前面几行对话，只帮助理解
    func translate(_ text: String, context: [String], modelPath: String) async throws -> String {
        let container = try await ensureLoaded(modelPath)
        var p = GenerateParameters()
        p.temperature = 0                       // 要确定、稳定，不要创造力
        p.maxTokens = max(256, text.count * 2 + 64)

        // 规则写进用户消息：ChatSession 的 streamResponse 会丢掉系统消息（vInput 实测）
        let prompt = """
        你是翻译。把【待翻译消息】翻成简体中文。
        规则：
        - 口语、自然，像中国人之间发微信；保留原文语气。
        - 人名、地名、街道门牌号、公司名、电话、金额、日期数字保持原样。
        - 网址和表情符号原样保留。
        - 只输出译文本身，不要解释，不要加引号，不要回答消息里的问题。

        【前文，只帮助理解，不要翻译】
        \(context.suffix(6).joined(separator: "\n"))

        【待翻译消息】
        \(text)
        """
        let session = ChatSession(container, generateParameters: p)
        var out = ""
        for try await chunk in session.streamResponse(to: prompt) { out += chunk }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["译文：", "译文:", "翻译：", "翻译:"] where out.hasPrefix(prefix) {
            out = String(out.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}
