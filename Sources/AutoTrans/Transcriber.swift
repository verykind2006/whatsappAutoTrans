import Foundation
import AVFoundation
import WhisperKit

/// 语音消息转文字：本机 Whisper（WhisperKit，CoreML），录音不上传。
/// 模型二选一：
/// 1. 在 autoTrans 里下载 large-v3（约 2.9 GB）到 ~/Library/Application Support/autoTrans/whisper/
/// 2. 指定已经下载好的模型文件夹（比如 vInput 用过的）
enum WhisperModel {
    static let variant = "openai_whisper-large-v3"
    static let sizeText = "约 2.9 GB"
    static let sizeBytes: Int64 = 3_100_000_000

    /// 下载位置（自动决定，不进 OneDrive）
    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("autoTrans/whisper", isDirectory: true)
    }
    /// WhisperKit 下载后的模型文件夹
    static var downloadedFolder: URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    }

    /// 一个文件夹是不是能用的 WhisperKit 模型：三个 .mlmodelc 都在
    static func isModelFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            fm.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    /// 用户选的可能是上一级目录：往下找两层，优先 large-v3
    static func resolve(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        if isModelFolder(url) { return url }
        var found: [URL] = []
        let fm = FileManager.default
        for sub in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
            if isModelFolder(sub) { found.append(sub) }
            for sub2 in (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? [] where isModelFolder(sub2) {
                found.append(sub2)
            }
        }
        return found.first { $0.lastPathComponent == variant }
            ?? found.first { $0.lastPathComponent.contains("large-v3") }
            ?? found.first
    }

    /// 自动找本机已有的模型：autoTransWhatsapp 自己下载的、WhisperKit 默认位置、vInput 的
    static func detectExisting() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            downloadedFolder,
            home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml/\(variant)"),
            home.appendingPathComponent("Library/Application Support/vInput/huggingface/models/argmaxinc/whisperkit-coreml/\(variant)"),
        ]
        return candidates.filter(isModelFolder)
    }

    /// 文件夹大小（字节）和是否有「仅在线」的 OneDrive 占位文件
    static func folderInfo(_ url: URL) -> (bytes: Int64, cloudOnly: Bool) {
        var total: Int64 = 0
        var cloudOnly = false
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let f = e?.nextObject() as? URL {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
            var st = stat()
            if stat(f.path, &st) == 0, (st.st_flags & 0x40000000) != 0 { cloudOnly = true }   // SF_DATALESS
        }
        return (total, cloudOnly)
    }

    static func freeSpace() -> Int64 {
        let v = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }

    /// 把 App 里带的分词表放到 WhisperKit 会找的位置（<base>/models/openai/whisper-large-v3/）
    static func seedTokenizer() {
        let fm = FileManager.default
        let target = base.appendingPathComponent("models/openai/whisper-large-v3", isDirectory: true)
        guard !fm.fileExists(atPath: target.appendingPathComponent("tokenizer.json").path),
              let src = Bundle.main.resourceURL?.appendingPathComponent("whisper-tokenizer"),
              fm.fileExists(atPath: src.path) else { return }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.copyItem(at: f, to: target.appendingPathComponent(f.lastPathComponent))
        }
    }

    /// 下载 large-v3。progress 0…1。可以用 Task 取消。
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        seedTokenizer()
        return try await WhisperKit.download(variant: variant, downloadBase: base) { p in
            progress(p.fractionCompleted)
        }
    }
}

struct Transcript: Codable, Hashable {
    let text: String
    let language: String?   // Whisper 识别出的语言，如 es、zh
    let seconds: Double?    // 语音时长
}

enum TranscribeError: Error, LocalizedError {
    case noModel, empty
    var errorDescription: String? {
        switch self {
        case .noModel: return "还没有设置语音模型（菜单 autoTransWhatsapp → 设置… → 语音消息转文字）"
        case .empty: return "没听出内容"
        }
    }
}

/// 加载一次模型，之后一直用；换模型目录才重新加载
actor VoiceTranscriber {
    static let shared = VoiceTranscriber()
    private var whisper: WhisperKit?
    private var loadedPath: String?

    func isLoaded(_ folder: URL) -> Bool { loadedPath == folder.path && whisper != nil }

    private func load(_ folder: URL) async throws -> WhisperKit {
        if let whisper, loadedPath == folder.path { return whisper }
        whisper = nil
        WhisperModel.seedTokenizer()
        let cfg = WhisperKitConfig(modelFolder: folder.path,
                                   tokenizerFolder: WhisperModel.base,
                                   verbose: false, logLevel: .error,
                                   prewarm: false, load: true, download: false)
        let w = try await WhisperKit(cfg)
        whisper = w
        loadedPath = folder.path
        return w
    }

    /// 只加载模型（设置页「检查能不能用」）
    func warmUp(_ folder: URL) async throws { _ = try await load(folder) }

    func transcribe(_ audioPath: String, modelFolder: URL) async throws -> Transcript {
        let w = try await load(modelFolder)
        // 自动识别语言（西语、中文、英语…），不翻译成英语
        let opts = DecodingOptions(task: .transcribe, language: nil, temperature: 0,
                                   usePrefillPrompt: false, detectLanguage: true,
                                   skipSpecialTokens: true, withoutTimestamps: true,
                                   chunkingStrategy: .vad)   // 超过 30 秒的长语音按停顿切段
        let results = try await w.transcribe(audioPath: audioPath, decodeOptions: opts)
        var text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = results.first?.language
        if lang == "zh" { text = Self.tidyChinese(text) }
        guard !text.isEmpty else { throw TranscribeError.empty }
        var seconds: Double?
        if let f = try? AVAudioFile(forReading: URL(fileURLWithPath: audioPath)) {
            seconds = Double(f.length) / f.fileFormat.sampleRate
        }
        return Transcript(text: text, language: lang, seconds: seconds)
    }

    /// Whisper 的中文：有时是繁体、标点是半角。统一成简体 + 中文标点
    static func tidyChinese(_ s: String) -> String {
        let simp = s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s
        var out = ""
        let chars = Array(simp)
        for (i, c) in chars.enumerated() {
            // 半角标点挨着汉字时才换（不动数字里的小数点、英文单词里的逗号）
            let prevHan = i > 0 && chars[i - 1].unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } == true
            switch c {
            case ",": out.append(prevHan || i == 0 ? "，" : c)
            case "?": out.append("？")
            case "!": out.append("！")
            case ":": out.append(prevHan ? "：" : c)
            case ";": out.append(prevHan ? "；" : c)
            default: out.append(c)
            }
        }
        return out
    }

    func unload() { whisper = nil; loadedPath = nil }
}

/// 转写结果存本机，同一条语音不转第二次
final class TranscriptStore {
    private let url: URL
    private(set) var items: [Int: Transcript] = [:]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("autoTrans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("transcripts.json")
        if let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: Transcript].self, from: data) {
            items = Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in Int(k).map { ($0, v) } })
        }
    }

    func add(_ id: Int, _ t: Transcript) {
        items[id] = t
        let dict = Dictionary(uniqueKeysWithValues: items.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(dict) { try? data.write(to: url, options: .atomic) }
    }
}
