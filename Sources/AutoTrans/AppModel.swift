import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var hasDBAccess = false
    /// 首次设置向导走完没有（新机器第一次打开为 false）
    @Published var setupDone: Bool = UserDefaults.standard.bool(forKey: "setupDone") {
        didSet { UserDefaults.standard.set(setupDone, forKey: "setupDone") }
    }
    @Published var chats: [Chat] = []
    /// WhatsApp 有没有打开并登录；没有就停在提示页
    @Published var waState: WhatsAppSender.AppState = .ready
    private var waCheckedAt = Date.distantPast

    /// 字号缩放（⌘+ / ⌘- / ⌘0），存在本机
    @Published var fontScale: Double = {
        let v = UserDefaults.standard.double(forKey: "fontScale"); return v == 0 ? 1 : v
    }() {
        didSet { Theme.scale = fontScale; UserDefaults.standard.set(fontScale, forKey: "fontScale") }
    }
    func zoom(_ step: Int) {
        fontScale = step == 0 ? 1 : min(1.8, max(0.8, ((fontScale + Double(step) * 0.1) * 10).rounded() / 10))
    }
    private var keyMonitor: Any?
    /// 每个聊天的最后一条消息（左侧列表预览）
    @Published var previews: [Int: Message] = [:]
    @Published var selectedChatID: Int? {
        didSet {
            guard oldValue != selectedChatID else { return }
            if selectedChatID != nil { composingNew = false }   // 点了某个聊天，就退出「新消息」
            resetCompose()   // 换了聊天，旧译文作废（中文草稿保留）
            reloadMessages()
            refreshUnread()   // 点开就算已读
        }
    }
    /// 每个聊天有几条「还没在 autoTrans 里看过」的新消息
    @Published var unread: [Int: Int] = [:]
    /// 每个聊天看到哪条为止（消息编号），存在本机
    private var lastSeen: [Int: Int] = {
        let d = UserDefaults.standard.dictionary(forKey: "lastSeen") as? [String: Int] ?? [:]
        return Dictionary(uniqueKeysWithValues: d.compactMap { k, v in Int(k).map { ($0, v) } })
    }() {
        didSet {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: lastSeen.map { (String($0.key), $0.value) }),
                                      forKey: "lastSeen")
        }
    }
    @Published var messages: [Message] = []
    @Published var translations: [Int: String] = [:]
    @Published var pending: Set<Int> = []
    @Published var status = ""
    @Published var errorText: String?
    @Published var pinned: Bool = UserDefaults.standard.bool(forKey: "pinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "pinned"); WindowPin.apply(pinned) }
    }

    @Published var engine: TranslationEngine =
        TranslationEngine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .online {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: "engine")
            configChanged()
            if engine == .online { Task { await LocalTranslator.shared.unload() } }
        }
    }

    // 联网模型的配置
    @Published var provider: OnlineProvider =
        OnlineProvider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .anthropic {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "provider"); configChanged() }
    }
    /// 只有「其他（OpenAI 兼容）」需要用户填接口地址
    @Published var customBaseURL: String = UserDefaults.standard.string(forKey: "customBaseURL") ?? "" {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: "customBaseURL") }
    }
    /// 每家选用的模型名，按服务商分别记
    @Published var models: [String: String] = UserDefaults.standard.dictionary(forKey: "models") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(models, forKey: "models"); configChanged() }
    }
    /// 本机存的各家有没有 key（缓存一下）
    @Published var keyStored: [OnlineProvider: Bool] = [:]

    var baseURL: String { provider == .custom ? customBaseURL : provider.defaultBaseURL }
    var modelName: String { models[provider.rawValue] ?? provider.defaultModel ?? "" }
    var hasKey: Bool { keyStored[provider] ?? false }

    /// 当前翻译方式是否已经可以用；不能用时说明缺什么
    var configProblem: String? {
        switch engine {
        case .online:
            if baseURL.isEmpty { return "还没有填接口地址" }
            if !hasKey { return "还没有填 \(provider.title) 的 API key" }
            if modelName.isEmpty { return "还没有选模型" }
            return nil
        case .local:
            return LocalTranslator.checkDirectory(localModelPath).first { !$0.ok }?.text
        }
    }

    func onlineConfig() -> OnlineConfig? {
        guard configProblem == nil, let key = KeyStore.readKey(account: provider.keychainAccount) else { return nil }
        return OnlineConfig(provider: provider, baseURL: baseURL, apiKey: key, model: modelName)
    }

    private func configChanged() {
        errorText = nil
        retryAfter = .distantPast
        translateMissing()
    }
    @Published var localModelPath: String =
        UserDefaults.standard.string(forKey: "localModelPath") ?? "" {
        didSet { UserDefaults.standard.set(localModelPath, forKey: "localModelPath") }
    }

    private let db = WhatsAppDB()
    private let cache = TranslationCache()
    private let sentStore = SentStore()
    /// 经 autoTrans 发出的消息：编号 → 用户写的中文
    @Published var sentRecords: [Int: SentRecord] = [:]
    private var lastMaxID = -1
    private var timer: Timer?
    private var translating = false
    private var retryAfter = Date.distantPast

    var selectedChat: Chat? { chats.first { $0.id == selectedChatID } }

    func start() {
        Theme.scale = fontScale
        // ⌘+ / ⌘= 放大，⌘- 缩小，⌘0 恢复（菜单「显示」里也有）
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .numericPad]) == .command,
                  let c = e.charactersIgnoringModifiers else { return e }
            switch c {
            case "+", "=": self?.zoom(1)
            case "-", "_": self?.zoom(-1)
            case "0": self?.zoom(0)
            default: return e
            }
            return nil
        }
        checkWhatsApp(force: true)
        translations = cache.items
        sentRecords = sentStore.items
        transcripts = transcriptStore.items
        refreshKeyStatus()
        checkAccess()
        Notifier.shared.onOpenChat = { [weak self] id in self?.selectedChatID = id }
        Notifier.shared.setup()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        WindowPin.apply(pinned)
    }

    func checkAccess() {
        hasDBAccess = db.canOpen()
        if hasDBAccess { lastMaxID = -1; poll() }
    }

    func refreshKeyStatus() {
        var s: [OnlineProvider: Bool] = [:]
        for p in OnlineProvider.allCases { s[p] = KeyStore.readKey(account: p.keychainAccount) != nil }
        keyStored = s
    }

    /// 先用 key 拉一次模型列表（免费）验证，通过了才存到本机。返回可用模型列表。
    func verifyAndSaveKey(_ key: String, for p: OnlineProvider) async throws -> [String] {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = p == .custom ? customBaseURL : p.defaultBaseURL
        guard !base.isEmpty else { throw TranslateError.notConfigured("请先填接口地址") }
        let list = try await OnlineTranslator.listModels(provider: p, baseURL: base, apiKey: trimmed)
        guard KeyStore.saveKey(trimmed, account: p.keychainAccount) else {
            throw TranslateError.notConfigured("保存 key 到本机文件失败")
        }
        refreshKeyStatus()
        configChanged()
        return list
    }

    /// 用已存的 key 拉模型列表（设置页打开时用）
    func availableModels(for p: OnlineProvider) async throws -> [String] {
        guard let key = KeyStore.readKey(account: p.keychainAccount) else { return [] }
        let base = p == .custom ? customBaseURL : p.defaultBaseURL
        return try await OnlineTranslator.listModels(provider: p, baseURL: base, apiKey: key)
    }

    /// 每 3 秒看一眼：有没有新消息
    /// 检查 WhatsApp。没准备好时每次轮询都查；准备好以后只看它还在不在运行，每 30 秒再细查一次
    func checkWhatsApp(force: Bool = false) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: WhatsAppSender.bundleID)
            .contains { !$0.isTerminated }
        // 窗口开关很便宜，每次都查：关了马上显示顶部提示，开了马上去掉
        if running, !force, waState == .ready || waState == .noWindow, let n = WhatsAppSender.windowCount() {
            if n == 0 { if waState != .noWindow { waState = .noWindow }; return }
            if waState == .noWindow { waCheckedAt = .distantPast }   // 窗口刚打开：马上细查一次
        }
        if waState == .ready || waState == .unknown, running, !force, Date().timeIntervalSince(waCheckedAt) < 30 { return }
        waCheckedAt = Date()
        var names = chats.map(\.name)
        if names.isEmpty { names = ((try? db.chats()) ?? []).map(\.name) }
        let st = WhatsAppSender.appState(knownChats: names)
        if st != waState { waState = st }
    }

    func poll() {
        checkWhatsApp()
        guard hasDBAccess else { return }
        do {
            let maxID = try db.maxMessageID()
            if notifyAfterID == nil { notifyAfterID = maxID }   // 只提醒 autoTrans 打开以后来的消息
            handleNewIncoming()
            guard maxID != lastMaxID else {
                if Date() > retryAfter { translateMissing() }
                transcribeVisible()
                return
            }
            lastMaxID = maxID
            chats = try db.chats()
            previews = (try? db.lastMessages()) ?? previews
            if selectedChatID == nil, !composingNew, let newest = chats.first?.id {
                selectedChatID = newest   // 刚打开时选最近的聊天；didSet 里会读消息
                return
            }
            reloadMessages()
            refreshUnread()
        } catch {
            errorText = "读取 WhatsApp 数据出错：\(error.localizedDescription)"
        }
    }

    // MARK: 新消息：单聊后台先翻好 + 系统通知

    private var notifyAfterID: Int?
    private var notified: Set<Int> = []       // 已经发过通知（或决定不发）的消息
    private var bgInFlight: Set<Int> = []     // 正在后台翻译的消息
    private var bgFailed: Set<Int> = []       // 后台翻译失败的：通知里直接显示原文

    /// 每次轮询都看一眼：打开 autoTrans 之后，单聊里对方发来的新消息。
    /// 需要翻译的先翻（不在当前聊天的也翻），翻好了再发通知；群聊不翻不通知，只显示角标。
    private func handleNewIncoming() {
        guard setupDone, let floor = notifyAfterID,
              let rows = try? db.incomingMessages(after: floor) else { return }
        for (chatID, list) in Dictionary(grouping: rows, by: { $0.0 }) {
            let ids = Set(list.map { $0.1 }).subtracting(notified).subtracting(bgInFlight)
            guard !ids.isEmpty else { continue }
            guard let chat = chats.first(where: { $0.id == chatID }), !chat.isGroup else {
                if chats.contains(where: { $0.id == chatID }) { notified.formUnion(ids) }   // 群聊：跳过
                continue
            }
            guard let raw = try? db.messages(chatID: chatID, limit: 20) else { continue }
            let recent = withTranscripts(raw)
            let newOnes = recent.filter { ids.contains($0.id) }
            notified.formUnion(ids.subtracting(newOnes.map(\.id)))   // 一下子来太多、不在最近 20 条里的，不提醒

            // 还没翻译的外语消息：当前打开的聊天交给 translateMissing，其他聊天在后台翻
            let untranslated = newOnes.filter {
                $0.needsTranslation && translations[$0.id] == nil && sentRecords[$0.id] == nil && !bgFailed.contains($0.id)
            }
            if !untranslated.isEmpty {
                if chatID != selectedChatID { translateInBackground(chat: chat, recent: recent, targets: untranslated) }
                else if configProblem != nil { bgFailed.formUnion(untranslated.map(\.id)) }
            }
            // 语音：能转文字的先转（排队），转完再翻译、再通知
            let voicePending = newOnes.filter { needsTranscript($0) }
            voicePending.forEach(enqueueTranscription)
            let waiting = Set(untranslated.map(\.id)).union(voicePending.map(\.id))

            for m in newOnes where !waiting.contains(m.id) {
                notified.insert(m.id)
                // 正在看这个聊天，就不用通知了
                if chatID == selectedChatID && NSApp.isActive { continue }
                Notifier.shared.post(chatID: chatID, messageID: m.id, title: chat.name, body: notificationText(m))
            }
        }
    }

    private func notificationText(_ m: Message) -> String {
        if let zh = translations[m.id] { return m.kind == .audio ? "🎤 " + zh : zh }
        if m.kind == .audio, !m.text.isEmpty { return "🎤 " + m.text }
        let label: String
        switch m.kind {
        case .image: label = "[图片]"
        case .video: label = "[视频]"
        case .audio: label = "[语音消息]"
        case .document: label = "[文件]"
        default: label = ""
        }
        let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [label, t].filter { !$0.isEmpty }.joined(separator: " ").ifEmpty("[新消息]")
    }

    private func translateInBackground(chat: Chat, recent: [Message], targets: [Message]) {
        let ids = targets.map(\.id)
        if configProblem != nil { bgFailed.formUnion(ids); return }
        bgInFlight.formUnion(ids)
        let transcript = recent.filter { !$0.text.isEmpty }.map { m in
            OnlineTranslator.Line(id: m.id, speaker: speakerName(m, in: chat), text: m.text)
        }
        let path = localModelPath
        Task {
            var result: [Int: String] = [:]
            do {
                if engine == .local {
                    for m in targets {
                        let ctx = transcript.filter { $0.id < m.id }.map { "\($0.speaker)：\($0.text)" }
                        let zh = try await LocalTranslator.shared.translate(m.text, context: ctx, modelPath: path)
                        if !zh.isEmpty { result[m.id] = zh }
                    }
                } else if let cfg = onlineConfig() {
                    result = try await OnlineTranslator.translate(cfg, chatName: chat.name, isGroup: false,
                                                                  transcript: transcript, targetIDs: ids)
                }
            } catch {}
            if !result.isEmpty { cache.merge(result); translations = cache.items }
            bgInFlight.subtract(ids)
            bgFailed.formUnion(ids.filter { translations[$0] == nil })   // 没翻成的，通知里显示原文
            handleNewIncoming()
        }
    }

    // MARK: 语音消息转文字（本机 Whisper，可选）

    /// 用户设置的模型目录（下载的，或自己指定的）；空 = 没开这个功能
    @Published var whisperPath: String = UserDefaults.standard.string(forKey: "whisperPath") ?? "" {
        didSet {
            UserDefaults.standard.set(whisperPath, forKey: "whisperPath")
            whisperFolder = WhisperModel.resolve(whisperPath)
            transcribeFailed = []
        }
    }
    /// 解析后真正能用的模型文件夹；nil = 语音转文字没开或目录不对
    @Published private(set) var whisperFolder: URL? = WhisperModel.resolve(UserDefaults.standard.string(forKey: "whisperPath") ?? "")
    @Published var transcripts: [Int: Transcript] = [:]
    @Published var transcribing: Set<Int> = []
    @Published var transcribeFailed: Set<Int> = []
    /// 下载进度 0…1；nil = 没在下载
    @Published var whisperDownload: Double?
    @Published var whisperMessage: String?
    private var whisperDownloadTask: Task<Void, Never>?
    private let transcriptStore = TranscriptStore()
    private var voiceQueue: [(id: Int, path: String)] = []
    private var voiceWorking = false

    private func withTranscripts(_ list: [Message]) -> [Message] {
        list.map { m in
            guard m.kind == .audio, m.text.isEmpty, let t = transcripts[m.id] else { return m }
            return m.withTranscript(t.text)
        }
    }

    func needsTranscript(_ m: Message) -> Bool {
        m.kind == .audio && m.text.isEmpty && whisperFolder != nil && m.mediaPath != nil
            && transcripts[m.id] == nil && !transcribeFailed.contains(m.id)
    }

    /// 当前打开的聊天里，还没转文字的语音
    func transcribeVisible() {
        guard whisperFolder != nil else { return }
        messages.filter(needsTranscript).forEach(enqueueTranscription)
    }

    private func enqueueTranscription(_ m: Message) {
        guard let path = m.mediaPath, !transcribing.contains(m.id),
              !voiceQueue.contains(where: { $0.id == m.id }) else { return }
        voiceQueue.append((m.id, path))
        transcribing.insert(m.id)
        runVoiceQueue()
    }

    /// 一条一条转（模型只有一份，同时转没有好处）
    private func runVoiceQueue() {
        guard !voiceWorking, !voiceQueue.isEmpty, let folder = whisperFolder else { return }
        voiceWorking = true
        let job = voiceQueue.removeFirst()
        Task {
            let firstLoad = !(await VoiceTranscriber.shared.isLoaded(folder))
            if firstLoad { status = "正在加载语音模型（第一次要几分钟，以后很快）…" }
            else { status = "正在把语音转成文字…" }
            do {
                let t = try await VoiceTranscriber.shared.transcribe(job.path, modelFolder: folder)
                transcriptStore.add(job.id, t)
                transcripts = transcriptStore.items
            } catch {
                transcribeFailed.insert(job.id)
            }
            transcribing.remove(job.id)
            status = ""
            voiceWorking = false
            reloadMessages()          // 把文字放进消息，翻译会接着做
            translateMissing()
            handleNewIncoming()       // 等着这条语音的通知可以发了
            runVoiceQueue()
        }
    }

    func useWhisperFolder(_ path: String) {
        guard let url = WhisperModel.resolve(path) else {
            whisperMessage = "✗ 这个文件夹里没找到 Whisper 模型（应有 AudioEncoder.mlmodelc、TextDecoder.mlmodelc、MelSpectrogram.mlmodelc）"
            return
        }
        whisperPath = url.path
        whisperMessage = "✓ 已使用：\(url.lastPathComponent)"
    }

    func disableWhisper() {
        whisperPath = ""
        whisperMessage = nil
        Task { await VoiceTranscriber.shared.unload() }
    }

    func startWhisperDownload() {
        guard whisperDownload == nil else { return }
        let free = WhisperModel.freeSpace()
        if free > 0 && free < WhisperModel.sizeBytes + 1_000_000_000 {
            whisperMessage = "✗ 磁盘空间不够：需要约 4 GB，现在只剩 \(WhisperModel.gb(free))"
            return
        }
        whisperDownload = 0
        whisperMessage = nil
        whisperDownloadTask = Task {
            do {
                let url = try await WhisperModel.download { p in
                    Task { @MainActor in if self.whisperDownload != nil { self.whisperDownload = p } }
                }
                whisperDownload = nil
                useWhisperFolder(url.path)
                if whisperFolder != nil { whisperMessage = "✓ 下载完成，已启用。第一次转语音时还要加载几分钟。" }
            } catch {
                whisperDownload = nil
                whisperMessage = Task.isCancelled ? "已取消下载（已下完的文件会保留，下次接着下）"
                    : "✗ 下载失败：\(error.localizedDescription)。可以再点一次下载，会接着下。"
            }
        }
    }

    func cancelWhisperDownload() {
        whisperDownloadTask?.cancel()
        whisperDownloadTask = nil
        whisperDownload = nil
        whisperMessage = "已取消下载（已下完的文件会保留，下次接着下）"
    }

    /// 重算左侧列表的新消息数。当前打开的聊天视为已读。
    func refreshUnread() {
        guard hasDBAccess, let latest = try? db.latestIncomingByChat() else { return }
        var seen = lastSeen
        for c in chats where seen[c.id] == nil {
            seen[c.id] = latest[c.id] ?? 0      // 第一次见到的聊天：旧消息都算已读
        }
        if let sel = selectedChatID, let l = latest[sel] { seen[sel] = max(seen[sel] ?? 0, l) }
        if seen != lastSeen { lastSeen = seen }

        let minSeen = seen.values.min() ?? 0
        var counts: [Int: Int] = [:]
        for (chat, id) in (try? db.incomingMessages(after: minSeen)) ?? [] where id > (seen[chat] ?? 0) {
            counts[chat, default: 0] += 1
        }
        if counts != unread { unread = counts }
    }

    func reloadMessages() {
        guard let id = selectedChatID else { messages = []; return }
        do {
            messages = withTranscripts(try db.messages(chatID: id))
            transcribeVisible()
            errorText = nil
        } catch {
            errorText = "读取消息出错：\(error.localizedDescription)"
        }
        translateMissing()
    }

    /// 把当前聊天里还没翻译的外语消息，一次性发给联网模型翻（本机模型则逐条翻）
    func translateMissing() {
        guard setupDone, !translating, Date() > retryAfter, let chat = selectedChat else { return }
        // 经 autoTrans 发出的消息已经有中文原文，不用再翻
        let targets = messages.filter { $0.needsTranslation && translations[$0.id] == nil && sentRecords[$0.id] == nil }
        guard !targets.isEmpty else { status = ""; return }
        if let problem = configProblem { errorText = "翻译没开始：\(problem)（菜单 autoTrans → 设置…）"; return }

        let transcript = messages.filter { !$0.text.isEmpty }.map { m in
            OnlineTranslator.Line(id: m.id, speaker: speakerName(m, in: chat), text: m.text)
        }
        let ids = targets.map(\.id)

        if engine == .local { translateLocally(targets: targets, transcript: transcript); return }
        guard let cfg = onlineConfig() else { return }

        translating = true
        pending.formUnion(ids)
        status = "正在翻译 \(ids.count) 条…"

        Task {
            defer { translating = false; pending.subtract(ids) }
            do {
                let result = try await OnlineTranslator.translate(
                    cfg, chatName: chat.name, isGroup: chat.isGroup, transcript: transcript, targetIDs: ids)
                cache.merge(result)
                translations = cache.items
                status = ""
                errorText = nil
                // 模型偶尔漏翻某条：剩下的下一轮再翻，但先等一会儿，免得一直重试
                if ids.contains(where: { result[$0] == nil }) { retryAfter = Date().addingTimeInterval(30) }
            } catch {
                status = ""
                errorText = error.localizedDescription
                retryAfter = Date().addingTimeInterval(60)  // 出错后 1 分钟内不再重试，防止乱扣钱
            }
        }
    }

    /// 本机模型：一条一条翻（7B 小模型一次翻多条容易串行、漏条），从最新的开始
    private func translateLocally(targets: [Message], transcript: [OnlineTranslator.Line]) {
        let path = localModelPath
        translating = true
        pending.formUnion(targets.map(\.id))
        Task {
            defer { translating = false; pending.subtract(targets.map(\.id)) }
            for (n, m) in targets.reversed().enumerated() {
                guard engine == .local else { return }   // 中途切回联网模型就停
                let loaded = await LocalTranslator.shared.isLoaded(path)
                status = n == 0 && !loaded
                    ? "正在加载本机模型（第一次要十几秒到一分钟）…"
                    : "本机模型翻译中：第 \(n + 1)/\(targets.count) 条…"
                let ctx = transcript.filter { $0.id < m.id }.map { "\($0.speaker)：\($0.text)" }
                do {
                    let zh = try await LocalTranslator.shared.translate(m.text, context: ctx, modelPath: path)
                    if !zh.isEmpty { cache.merge([m.id: zh]); translations = cache.items }
                    pending.remove(m.id)
                } catch {
                    status = ""
                    errorText = "本机模型出错：\(error.localizedDescription)（请在设置里检查模型目录）"
                    retryAfter = Date().addingTimeInterval(60)
                    return
                }
            }
            status = ""
            errorText = nil
        }
    }

    // MARK: - 发消息（第二期）

    /// 用户打的中文
    @Published var draft = "" {
        didSet { if draft != oldValue, outgoingText != nil { outgoingText = nil; backTranslation = "" } }  // 改了中文，旧译文作废
    }
    /// 译文（用户可以改）；nil 表示还没翻译
    @Published var outgoingText: String?
    @Published var backTranslation = ""
    @Published var composeBusy = false
    @Published var composeStatus: String?
    @Published var composeError: String?

    /// 每个聊天记住发消息用的语言（房东 = 西语），默认西语
    @Published private var chatLanguages: [String: String] =
        UserDefaults.standard.dictionary(forKey: "chatLanguages") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(chatLanguages, forKey: "chatLanguages") }
    }
    var targetLanguage: TargetLanguage {
        get {
            if composingNew { return newChatLanguage }
            return selectedChatID.flatMap { chatLanguages[String($0)] }.flatMap(TargetLanguage.init) ?? .es
        }
        set {
            if composingNew { newChatLanguage = newValue; outgoingText = nil; backTranslation = ""; return }
            guard let id = selectedChatID else { return }
            chatLanguages[String(id)] = newValue.rawValue
            outgoingText = nil; backTranslation = ""
        }
    }

    // MARK: 新消息：输入手机号，给还没聊过的人发

    /// true = 右边是「新消息」页面（输入手机号），不是某个已有聊天
    @Published var composingNew = false
    @Published var newChatPhone = ""
    @Published var newChatLanguage: TargetLanguage = .es

    func startNewChat() {
        composingNew = true
        selectedChatID = nil
        newChatPhone = ""
        resetCompose()
    }

    func cancelNewChat() {
        composingNew = false
        selectedChatID = chats.first?.id
    }

    /// 把用户输入的号码整理成「国家码 + 号码」的纯数字；不像号码就返回 nil。
    /// +34 600 123 456 / 0034600123456 / 600123456（9 位，默认西班牙）都行。
    static func normalizePhone(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var digits = t.filter(\.isASCII).filter(\.isNumber)
        guard !digits.isEmpty, t.allSatisfy({ $0.isNumber || " +-().".contains($0) }) else { return nil }
        if t.hasPrefix("+") {
            // 已带国家码
        } else if digits.hasPrefix("00") {
            digits.removeFirst(2)
        } else if digits.count == 9 {
            digits = "34" + digits        // 只写了 9 位：当作西班牙号码
        } else {
            return nil                    // 没写国家码又不是 9 位，猜不出来
        }
        return (8...15).contains(digits.count) ? digits : nil
    }

    var newChatDigits: String? { Self.normalizePhone(newChatPhone) }

    /// 发消息框上显示的「发给谁」
    var recipientLabel: String {
        if composingNew { return newChatDigits.map { "+" + $0 } ?? "新号码" }
        return selectedChat?.name ?? ""
    }

    func resetCompose() {
        outgoingText = nil; backTranslation = ""; composeStatus = nil; composeError = nil
    }

    /// 第一步：中文 → 对方的语言（附直译回中文）
    func translateDraft() {
        let chinese = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chinese.isEmpty, !composeBusy, composingNew || selectedChat != nil else { return }
        let chat = selectedChat ?? Chat(id: -1, name: recipientLabel, isGroup: false, lastDate: Date())
        composeError = nil; composeStatus = nil
        let lang = targetLanguage
        if lang == .zh { outgoingText = chinese; backTranslation = ""; return }
        if let problem = configProblem { composeError = "不能翻译：\(problem)（菜单 autoTrans → 设置…）"; return }

        let transcript = composingNew ? [] : messages.filter { !$0.text.isEmpty }.map { m in
            OnlineTranslator.Line(id: m.id, speaker: speakerName(m, in: chat), text: m.text)
        }
        composeBusy = true
        composeStatus = "正在翻译…"
        Task {
            defer { composeBusy = false }
            do {
                let r: OnlineTranslator.Outgoing
                if engine == .local {
                    r = try await LocalTranslator.shared.translateOutgoing(
                        chinese, to: lang, context: transcript.map { "\($0.speaker)：\($0.text)" }, modelPath: localModelPath)
                } else {
                    guard let cfg = onlineConfig() else { throw TranslateError.notConfigured("翻译设置不完整") }
                    r = try await OnlineTranslator.translateOutgoing(cfg, chinese: chinese, to: lang,
                                                                     chatName: chat.name, transcript: transcript)
                }
                guard draft.trimmingCharacters(in: .whitespacesAndNewlines) == chinese else { composeStatus = nil; return }
                outgoingText = r.translation
                backTranslation = r.backTranslation
                composeStatus = nil
            } catch {
                composeStatus = nil
                composeError = "翻译失败：\(error.localizedDescription)"
            }
        }
    }

    /// 第二步：发到 WhatsApp 里当前选中的聊天，并到数据库里确认真的发出去了
    func sendOutgoing() {
        if composingNew { sendToNewNumber(); return }
        guard let text = outgoingText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !composeBusy, let chat = selectedChat else { return }
        composeError = nil
        composeBusy = true
        composeStatus = "正在发到 WhatsApp…"
        let before = (try? db.maxMessageID()) ?? 0
        let chinese = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = targetLanguage
        Task {
            defer { composeBusy = false }
            do {
                do { try await WhatsAppSender.send(text, toChatNamed: chat.name) }
                catch { WhatsAppSender.bringAutoTransToFront(); throw error }
                WhatsAppSender.bringAutoTransToFront()   // 发完马上回到 autoTrans，再慢慢确认
                // 最多等 10 秒，看数据库里有没有出现这条「我发的」消息
                composeStatus = "已提交给 WhatsApp，正在确认…"
                var sentID: Int?
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(500))
                    let sent = (try? db.outgoingTexts(chatID: chat.id, after: before)) ?? []
                    if let hit = sent.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text }) {
                        sentID = hit.id; break
                    }
                }
                if let sentID {
                    // 记下中文原文：以后显示「中文为主，下面是实际发出的外语」，不再反过来翻译
                    sentStore.add(sentID, SentRecord(chinese: chinese, language: lang.rawValue))
                    sentRecords = sentStore.items
                    draft = ""; outgoingText = nil; backTranslation = ""
                    composeStatus = "✓ 已发送给「\(chat.name)」"
                    poll()
                } else {
                    composeStatus = nil
                    composeError = "没看到发出去的记录，请到 WhatsApp 里看一下这条消息是否已发出"
                }
            } catch {
                composeStatus = nil
                composeError = error.localizedDescription
            }
        }
    }

    /// 新消息：用 WhatsApp 官方链接打开这个号码的聊天并发送，再去数据库找它落在哪个聊天，然后切过去
    private func sendToNewNumber() {
        guard let text = outgoingText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !composeBusy else { return }
        guard let digits = newChatDigits else {
            composeError = "手机号不对。请写完整号码，例如 +34 600 123 456（西班牙号码可以只写 9 位）"
            return
        }
        composeError = nil
        composeBusy = true
        composeStatus = "正在让 WhatsApp 打开 +\(digits) 的聊天…"
        let before = (try? db.maxMessageID()) ?? 0
        let chinese = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = targetLanguage
        Task {
            defer { composeBusy = false }
            do {
                do { try await WhatsAppSender.send(text, toPhone: digits) }
                catch { WhatsAppSender.bringAutoTransToFront(); throw error }
                WhatsAppSender.bringAutoTransToFront()
                composeStatus = "已提交给 WhatsApp，正在确认…"
                var hit: (id: Int, chatID: Int, text: String)?
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(500))
                    let sent = (try? db.outgoingTextsAnyChat(after: before)) ?? []
                    hit = sent.first { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text }
                    if hit != nil { break }
                }
                guard let hit else {
                    composeStatus = nil
                    composeError = "没看到发出去的记录，请到 WhatsApp 里看一下这条消息是否已发出"
                    return
                }
                sentStore.add(hit.id, SentRecord(chinese: chinese, language: lang.rawValue))
                sentRecords = sentStore.items
                chatLanguages[String(hit.chatID)] = lang.rawValue   // 以后这个聊天默认用同一种语言
                draft = ""; outgoingText = nil; backTranslation = ""
                lastMaxID = -1
                poll()                                // 重新读聊天列表（新聊天会出现在最上面）
                selectedChatID = hit.chatID           // 切到这个聊天
                composeStatus = "✓ 已发送给 +\(digits)"
            } catch {
                composeStatus = nil
                composeError = error.localizedDescription
            }
        }
    }

    func speakerName(_ m: Message, in chat: Chat) -> String {
        if m.isFromMe { return "我" }
        return chat.isGroup ? (m.sender ?? "群成员") : chat.name
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
