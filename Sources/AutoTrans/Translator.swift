import Foundation

// MARK: - 联网翻译服务商

/// 联网翻译用哪家。
/// 只有两种「说话方式」（协议）：Anthropic 自己的，和业界通用的「OpenAI 兼容」格式。
/// OpenAI、DeepSeek，以及通义千问、Kimi、智谱等大多数服务商都支持后者，
/// 所以除了 Claude，其余全走同一段代码，只是网址、key、模型名不同；「自定义」可以填任意兼容服务。
enum OnlineProvider: String, CaseIterable, Identifiable {
    case anthropic, openai, deepseek, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: return "Claude（Anthropic）"
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .custom: return "其他（OpenAI 兼容）"
        }
    }

    /// 用 Anthropic 原生协议，还是 OpenAI 兼容协议
    var isAnthropic: Bool { self == .anthropic }

    /// 接口地址。custom 由用户填写。
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com"
        case .custom: return ""
        }
    }

    /// 本机 key 文件里的名字，每家各存一个 key
    var keychainAccount: String { "\(rawValue)-api-key" }

    /// 去哪里申请 key（给用户看）
    var keyHint: String {
        switch self {
        case .anthropic: return "在 platform.claude.com 生成，以 sk-ant- 开头"
        case .openai: return "在 platform.openai.com 生成，以 sk- 开头"
        case .deepseek: return "在 platform.deepseek.com 生成，以 sk- 开头"
        case .custom: return "填写该服务商给你的 API key"
        }
    }

    /// 只有 Claude 有一个明确推荐的默认模型；其他家让用户从「可用模型」列表里选，不凭记忆写死
    var defaultModel: String? { self == .anthropic ? "claude-opus-5-5" : nil }
}

/// 发消息时翻成哪种语言；每个聊天记住自己的选择（房东 = 西语）
enum TargetLanguage: String, CaseIterable, Identifiable {
    case es, en, zh
    var id: String { rawValue }
    var title: String {
        switch self {
        case .es: return "西班牙语"
        case .en: return "英语"
        case .zh: return "不翻译（直接发中文）"
        }
    }
    var promptName: String {
        switch self {
        case .es: return "西班牙语（西班牙本地用法）"
        case .en: return "英语"
        case .zh: return "中文"
        }
    }
}

/// 一次联网翻译需要的全部配置
struct OnlineConfig {
    let provider: OnlineProvider
    let baseURL: String
    let apiKey: String
    let model: String
}

enum TranslateError: Error, LocalizedError {
    case http(Int, String), refused, badResponse(String), notConfigured(String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            switch code {
            case 401: return "API key 无效（401），请在设置里重新填写"
            case 402, 403: return "账户余额不足或没有权限（\(code)）"
            case 404: return "接口地址或模型名不对（404）"
            case 429: return "请求太频繁或额度用完，稍后自动重试（429）"
            default: return "翻译服务出错（\(code)）：\(body.prefix(200))"
            }
        case .refused: return "模型拒绝翻译这几条消息"
        case .badResponse(let m): return "返回内容看不懂：\(m)"
        case .notConfigured(let m): return m
        }
    }
}

// MARK: - 联网翻译

enum OnlineTranslator {
    /// 一行对话记录
    struct Line {
        let id: Int
        let speaker: String
        let text: String
    }

    static let systemPrompt = """
    你是 WhatsApp 聊天翻译助手。使用者是住在西班牙的中国人，读不懂西班牙语和英语。
    你会收到一段对话记录（每行以 [编号] 开头）和一组「待翻译编号」。把每个待翻译编号对应的消息翻成简体中文。

    要求：
    - 口语、自然，像中国人之间发微信那样说话；保留原文语气（客气、着急、开玩笑、生气）。
    - 消息多半来自西班牙本地人，按西班牙西语理解；口语缩写（vale、porfa、q、xq、tb、finde 等）按意思翻。
    - 人名、地名、街道和门牌号、公司名、电话号码、金额、日期数字保持原样，不要音译。
    - 网址和表情符号原样保留。
    - 只翻译，不解释、不评论，也不要回答消息里的问题。
    - 对话记录里其他行只用来帮你理解上下文，不要翻译它们。
    - 每个待翻译编号都必须给出译文。
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "translations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["id": ["type": "integer"], "zh": ["type": "string"]],
                    "required": ["id", "zh"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["translations"],
        "additionalProperties": false,
    ]

    private static func userPrompt(chatName: String, isGroup: Bool, transcript: [Line], targetIDs: [Int]) -> String {
        let lines = transcript.map { "[\($0.id)] \($0.speaker)：\($0.text)" }.joined(separator: "\n")
        return """
        聊天：\(chatName)（\(isGroup ? "群聊" : "单聊")）

        <对话记录>
        \(lines)
        </对话记录>

        待翻译编号：\(targetIDs.map(String.init).joined(separator: ", "))
        """
    }

    static func translate(_ cfg: OnlineConfig, chatName: String, isGroup: Bool,
                          transcript: [Line], targetIDs: [Int]) async throws -> [Int: String] {
        let user = userPrompt(chatName: chatName, isGroup: isGroup, transcript: transcript, targetIDs: targetIDs)
        let text = cfg.provider.isAnthropic
            ? try await callAnthropic(cfg, user: user)
            : try await callOpenAICompatible(cfg, user: user)
        return try parse(text)
    }

    // Anthropic 原生协议（字段照 claude-api 技能里的 cURL 示例）
    private static func callAnthropic(_ cfg: OnlineConfig, user: String) async throws -> String {
        let body: [String: Any] = [
            "model": cfg.model,
            "max_tokens": 16000,
            // Opus 5.5 不能关思考，用 low 档：翻译不需要深想，更快更省
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
            // 万一被安全分类器拒绝，由服务器自动换一个模型重试
            "fallbacks": "default",
            "system": systemPrompt,
            "messages": [["role": "user", "content": user]],
        ]
        var req = request(cfg, path: "/messages", method: "POST")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(req)
        if (json["stop_reason"] as? String) == "refusal" { throw TranslateError.refused }
        // 只取 type == "text" 的块（还会有 thinking、fallback 等块）
        return (json["content"] as? [[String: Any]] ?? [])
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    // OpenAI 兼容协议：POST {baseURL}/chat/completions
    // 只发最基本的字段（model、messages），不发 temperature / max_tokens / response_format：
    // 各家对这几个字段支持不一，发了反而容易被拒。JSON 格式靠提示词要求，解析时再宽松处理。
    private static func callOpenAICompatible(_ cfg: OnlineConfig, user: String) async throws -> String {
        let body: [String: Any] = [
            "model": cfg.model,
            "messages": [
                ["role": "system", "content": systemPrompt + """

                输出格式：只输出一个 JSON 对象，不要任何别的文字，不要代码块标记：
                {"translations": [{"id": 编号, "zh": "译文"}]}
                """],
                ["role": "user", "content": user],
            ],
        ]
        var req = request(cfg, path: "/chat/completions", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(req)
        guard let choice = (json["choices"] as? [[String: Any]])?.first,
              let msg = choice["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw TranslateError.badResponse("没有 choices[0].message.content")
        }
        return content
    }

    /// 从模型回复里取出 {"translations": [...]}；容忍前后多余文字和 ```json 代码块
    private static func parse(_ text: String) throws -> [Int: String] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw TranslateError.badResponse(String(text.prefix(200)))
        }
        let jsonText = String(text[start...end])
        guard let inner = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any],
              let arr = inner["translations"] as? [[String: Any]] else {
            throw TranslateError.badResponse(String(text.prefix(200)))
        }
        var out: [Int: String] = [:]
        for item in arr {
            let id = (item["id"] as? NSNumber)?.intValue ?? (item["id"] as? String).flatMap(Int.init)
            if let id, let zh = item["zh"] as? String { out[id] = zh }
        }
        return out
    }

    // MARK: 发出去的消息：中文 → 对方的语言（附带直译回中文，方便不懂外语的人核对意思）

    struct Outgoing {
        let translation: String
        let backTranslation: String
    }

    static func outgoingSystemPrompt(_ lang: TargetLanguage) -> String {
        """
        你帮一位住在西班牙的中国人，把他写的中文消息翻成\(lang.promptName)，通过 WhatsApp 发给对方。
        要求：
        - 礼貌、口语、自然，像当地人之间发消息，不要书面腔，不要机翻味。
        \(lang == .es ? "- 用西班牙本地说法（例如用 vosotros、本地常用词），不要用拉美说法。\n" : "")\
        - 人名、地名、街道门牌号、金额、日期、电话保持原样。
        - 不要添加原文没有的意思，不要解释；表情符号保留。
        - 对话记录只帮你了解上下文和称呼，不要翻译它们。
        另外，把你的译文逐句直译回中文（back_translation），让不懂外语的人能核对意思有没有走样。
        """
    }

    private static let outgoingSchema: [String: Any] = [
        "type": "object",
        "properties": ["translation": ["type": "string"], "back_translation": ["type": "string"]],
        "required": ["translation", "back_translation"],
        "additionalProperties": false,
    ]

    static func translateOutgoing(_ cfg: OnlineConfig, chinese: String, to lang: TargetLanguage,
                                  chatName: String, transcript: [Line]) async throws -> Outgoing {
        let recent = transcript.suffix(10).map { "\($0.speaker)：\($0.text)" }.joined(separator: "\n")
        let user = """
        聊天对象：\(chatName)

        <最近的对话>
        \(recent)
        </最近的对话>

        <要翻译的中文>
        \(chinese)
        </要翻译的中文>
        """
        let text: String
        if cfg.provider.isAnthropic {
            let body: [String: Any] = [
                "model": cfg.model,
                "max_tokens": 16000,
                "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": outgoingSchema]],
                "fallbacks": "default",
                "system": outgoingSystemPrompt(lang),
                "messages": [["role": "user", "content": user]],
            ]
            var req = request(cfg, path: "/messages", method: "POST")
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let json = try await send(req)
            if (json["stop_reason"] as? String) == "refusal" { throw TranslateError.refused }
            text = (json["content"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }.joined()
        } else {
            let body: [String: Any] = [
                "model": cfg.model,
                "messages": [
                    ["role": "system", "content": outgoingSystemPrompt(lang) + """

                    输出格式：只输出一个 JSON 对象，不要任何别的文字，不要代码块标记：
                    {"translation": "译文", "back_translation": "直译回中文"}
                    """],
                    ["role": "user", "content": user],
                ],
            ]
            var req = request(cfg, path: "/chat/completions", method: "POST")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let json = try await send(req)
            guard let msg = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                throw TranslateError.badResponse("没有 choices[0].message.content")
            }
            text = content
        }
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(String(text[s...e]).utf8)) as? [String: Any],
              let tr = obj["translation"] as? String else {
            throw TranslateError.badResponse(String(text.prefix(200)))
        }
        return Outgoing(translation: tr.trimmingCharacters(in: .whitespacesAndNewlines),
                        backTranslation: (obj["back_translation"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: 验证 key + 列出可用模型（这两家接口都不收费）

    /// 用 key 拉取「可用模型」列表。成功就说明 key、网址都对。
    static func listModels(provider: OnlineProvider, baseURL: String, apiKey: String) async throws -> [String] {
        let cfg = OnlineConfig(provider: provider, baseURL: baseURL, apiKey: apiKey, model: "")
        let json = try await send(request(cfg, path: "/models", method: "GET"))
        let ids = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return ids.sorted()
    }

    // MARK: 底层

    static func requestFor(_ cfg: OnlineConfig, path: String) -> URLRequest { request(cfg, path: path, method: "POST") }
    static func sendFor(_ req: URLRequest) async throws -> [String: Any] { try await send(req) }

    private static func request(_ cfg: OnlineConfig, path: String, method: String) -> URLRequest {
        let base = cfg.baseURL.hasSuffix("/") ? String(cfg.baseURL.dropLast()) : cfg.baseURL
        var req = URLRequest(url: URL(string: base + path) ?? URL(string: "https://invalid.invalid")!)
        req.httpMethod = method
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if cfg.provider.isAnthropic {
            req.setValue(cfg.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw TranslateError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslateError.badResponse("不是 JSON")
        }
        return json
    }
}

// MARK: - 通过 autoTransWhatsapp 发出的消息：记住中文原文

/// 一条经 autoTransWhatsapp 发出的消息：用户写的中文 + 实际发出的语言
struct SentRecord: Codable {
    let chinese: String
    let language: String   // TargetLanguage.rawValue
}

/// 位置：~/Library/Application Support/autoTrans/sent.json，键是 WhatsApp 的消息编号
final class SentStore {
    private let url: URL
    private(set) var items: [Int: SentRecord] = [:]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("autoTrans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("sent.json")
        if let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: SentRecord].self, from: data) {
            items = Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in Int(k).map { ($0, v) } })
        }
    }

    func add(_ id: Int, _ rec: SentRecord) {
        items[id] = rec
        let dict = Dictionary(uniqueKeysWithValues: items.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(dict) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - 译文缓存

/// 翻译结果存在本机，重启后不用重新翻（也就不重复花钱）
/// 位置：~/Library/Application Support/autoTrans/translations.json
final class TranslationCache {
    private let url: URL
    private(set) var items: [Int: String] = [:]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("autoTrans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("translations.json")
        if let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            items = Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in Int(k).map { ($0, v) } })
        }
    }

    func merge(_ new: [Int: String]) {
        items.merge(new) { _, b in b }
        let dict = Dictionary(uniqueKeysWithValues: items.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(dict) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - 建议回复 + 说话风格

struct ReplySuggestion: Identifiable, Hashable {
    let id = UUID()
    let chinese: String     // 中文意思（给用户看、可改）
    let reply: String       // 要发出去的那种语言
    let note: String        // 这条的思路，几个字
}

extension OnlineTranslator {
    /// 通用：发一次请求，拿回一个 JSON 对象（Anthropic 用结构化输出，其他家靠提示词 + 宽松解析）
    static func callJSON(_ cfg: OnlineConfig, system: String, user: String,
                         schema: [String: Any], example: String, effort: String = "low") async throws -> [String: Any] {
        let text: String
        if cfg.provider.isAnthropic {
            let body: [String: Any] = [
                "model": cfg.model,
                "max_tokens": 16000,
                "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
                "fallbacks": "default",
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
            var req = requestFor(cfg, path: "/messages")
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let json = try await sendFor(req)
            if (json["stop_reason"] as? String) == "refusal" { throw TranslateError.refused }
            text = (json["content"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }.joined()
        } else {
            let body: [String: Any] = [
                "model": cfg.model,
                "messages": [
                    ["role": "system", "content": system + "\n\n输出格式：只输出一个 JSON 对象，不要任何别的文字，不要代码块标记，形如：\n" + example],
                    ["role": "user", "content": user],
                ],
            ]
            var req = requestFor(cfg, path: "/chat/completions")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let json = try await sendFor(req)
            guard let msg = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                throw TranslateError.badResponse("没有 choices[0].message.content")
            }
            text = content
        }
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(String(text[s...e]).utf8)) as? [String: Any] else {
            throw TranslateError.badResponse(String(text.prefix(200)))
        }
        return obj
    }

    /// 根据对话起草 3 条回复，用用户自己的口气
    static func suggestReplies(_ cfg: OnlineConfig, chatName: String, isGroup: Bool, transcript: [Line],
                               style: String, hint: String, to lang: TargetLanguage) async throws -> [ReplySuggestion] {
        let langLine = lang == .zh
            ? "回复用中文写，reply 和 chinese 填同样的内容。"
            : "reply 用\(lang.promptName)写\(lang == .es ? "（西班牙本地说法，不用拉美说法）" : "")，chinese 是它的中文意思（逐句对应，方便不懂外语的人核对）。"
        let system = """
        你是一位 WhatsApp 用户的回复助手。根据对话，以「我」（用户本人）的身份，起草「我」接下来要发的一条回复。
        要求：
        - 严格按照下面「我的说话风格」来写：称呼、客气程度、长短、常用说法、表情符号习惯都要像本人。
        - 接住对方最后说的话；对方问的问题要回答。不知道的事实（价格、库存、时间、地址等）不要编，用「[待确认：…]」标出来让用户自己填。
        - 给 3 条思路不同的回复（例如：简短确认 / 详细回答 / 追问或推进），每条附几个字的思路说明 note（中文）。
        - 如果用户给了「要点」，3 条都必须表达这些要点，只是写法不同。
        - \(langLine)
        - 只写回复本身，不要加引号或解释。
        """
        let recent = transcript.suffix(30).map { "\($0.speaker)：\($0.text)" }.joined(separator: "\n")
        let user = """
        聊天对象：\(chatName)\(isGroup ? "（群聊）" : "")

        <我的说话风格>
        \(style.isEmpty ? "（还没有总结，按礼貌、亲切、简洁的口气写）" : style)
        </我的说话风格>

        <最近的对话>
        \(recent.isEmpty ? "（还没有聊过，这是第一条消息）" : recent)
        </最近的对话>

        <我想说的要点>
        \(hint.isEmpty ? "（没有给要点，你根据对话判断该怎么回）" : hint)
        </我想说的要点>
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["suggestions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["note": ["type": "string"], "chinese": ["type": "string"], "reply": ["type": "string"]],
                    "required": ["note", "chinese", "reply"],
                    "additionalProperties": false,
                ],
            ]],
            "required": ["suggestions"],
            "additionalProperties": false,
        ]
        let obj = try await callJSON(cfg, system: system, user: user, schema: schema,
                                     example: #"{"suggestions":[{"note":"简短确认","chinese":"好的，周三见","reply":"Vale, nos vemos el miércoles"}]}"#,
                                     effort: "medium")
        let items = (obj["suggestions"] as? [[String: Any]] ?? []).compactMap { d -> ReplySuggestion? in
            guard let reply = (d["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else { return nil }
            let zh = (d["chinese"] as? String ?? reply).trimmingCharacters(in: .whitespacesAndNewlines)
            return ReplySuggestion(chinese: lang == .zh ? reply : zh, reply: reply,
                                   note: (d["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !items.isEmpty else { throw TranslateError.badResponse("没有给出建议") }
        return items
    }

    /// 从用户发过的消息里总结说话风格
    static func summarizeStyle(_ cfg: OnlineConfig, samples: [String]) async throws -> String {
        let system = """
        下面是一位 WhatsApp 用户自己发出去的消息（可能有中文、西班牙语、英语）。请总结这个人的说话风格，供以后替他/她代写回复时模仿。
        用中文分条写，300 字以内，包括：
        - 称呼和问候、结尾的习惯
        - 语气和客气程度（对客户 / 对熟人如果明显不同，分开说）
        - 句子长短、是否爱分几条发
        - 常用词、口头禅（各语言分别举例，直接引用原话片段）
        - 表情符号的使用习惯
        不要写具体的人名、电话、地址、价格等隐私或业务细节。
        """
        let user = samples.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let schema: [String: Any] = [
            "type": "object", "properties": ["style": ["type": "string"]],
            "required": ["style"], "additionalProperties": false,
        ]
        let obj = try await callJSON(cfg, system: system, user: user, schema: schema,
                                     example: #"{"style":"- 称呼：……"}"#)
        guard let s = (obj["style"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            throw TranslateError.badResponse("没有总结出来")
        }
        return s
    }
}
