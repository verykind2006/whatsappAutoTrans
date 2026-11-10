import AppKit
import ApplicationServices

/// 通过 macOS 辅助功能（Accessibility，macOS 27 叫「设备控制和数据访问」）操作 WhatsApp 发消息：
/// 像人一样点开左侧的聊天 → 核对右侧标题 → 往输入框填字 → 点发送。
/// 不改 WhatsApp 的程序、不用非官方接口。
///
/// 2026-11-10 实测 WhatsApp 的界面结构（中文界面）：
/// - 左侧每个聊天是一个 AXButton，description = 聊天名（电话号码会被拆成「+ 3 4,6 3 2,…」）
/// - 右侧打开的聊天，标题是一个 AXHeading，description = 聊天名
/// - 输入框是唯一的 AXTextArea（description「撰写消息」）
enum WhatsAppSender {
    static let bundleID = "net.whatsapp.WhatsApp"

    enum SendError: Error, LocalizedError {
        case notRunning, noPermission, noWindow, chatNotFound(String), wrongChat(String, String)
        case noInput, draftNotEmpty, couldNotSend, phoneNotOpened, pasteFailed, filePreviewNoSend
        var errorDescription: String? {
            switch self {
            case .notRunning: return "WhatsApp 没有打开，请先打开 WhatsApp"
            case .noPermission: return "autoTrans 还没有「设备控制和数据访问」（辅助功能）权限，不能操作 WhatsApp。请在设置向导或系统设置里打开"
            case .noWindow: return "WhatsApp 的窗口没有打开，请点一下程序坞里的 WhatsApp"
            case .chatNotFound(let n): return "在 WhatsApp 左侧列表里没找到「\(n)」。请先在 WhatsApp 里把这个聊天点开一次，再发送"
            case .wrongChat(let want, let got): return "WhatsApp 打开的是「\(got)」，不是「\(want)」，为防止发错人，没有发送"
            case .noInput: return "没找到 WhatsApp 的输入框，没有发送"
            case .draftNotEmpty: return "WhatsApp 里这个聊天的输入框已经有没发出去的文字。为了不覆盖它，没有发送，请先清空"
            case .pasteFailed: return "WhatsApp 没有把它当成文件（粘贴成了文字），已清掉，没有发送"
            case .filePreviewNoSend: return "文件已放进 WhatsApp，但没找到发送按钮。请切到 WhatsApp 看一下，手动点发送或取消"
            case .phoneNotOpened: return "WhatsApp 没有打开和这个号码的聊天。请检查号码；如果 WhatsApp 提示「号码不在 WhatsApp 上」，说明对方没用 WhatsApp"
            case .couldNotSend: return "已把译文填进 WhatsApp 的输入框，但没能自动发出。请切到 WhatsApp 按回车"
            }
        }
    }

    // MARK: 权限

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// 弹出系统的授权提示（会把 autoTrans 自动加进列表）
    static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: 发送

    /// 打开名为 chatName 的聊天并核对右侧确实是它；返回输入框
    @MainActor
    private static func openVerified(_ chatName: String) async throws -> (app: NSRunningApplication, window: AXUIElement, input: AXUIElement) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw SendError.notRunning
        }
        guard hasPermission else { throw SendError.noPermission }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var window = (attr(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first
        if window == nil {
            // 窗口关着：先把 WhatsApp 窗口打开，最多等 4 秒
            launchWhatsApp()
            for _ in 0..<20 where window == nil {
                try await Task.sleep(for: .milliseconds(200))
                window = (attr(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard let window else { throw SendError.noWindow }

        let want = norm(chatName)

        // 1. 如果没打开这个聊天，就点左侧列表里对应的那一行
        if !openChatTitles(window).contains(want) {
            guard let row = findAll(window, where: { role($0) == kAXButtonRole && norm(desc($0)) == want }).first else {
                throw SendError.chatNotFound(chatName)
            }
            AXUIElementPerformAction(row, kAXPressAction as CFString)
            // 最多等 3 秒，直到右侧标题变成这个聊天
            for _ in 0..<15 {
                try await Task.sleep(for: .milliseconds(200))
                if openChatTitles(window).contains(want) { break }
            }
        }

        // 2. 核对：右侧标题必须是这个聊天，否则不发
        guard openChatTitles(window).contains(want) else {
            throw SendError.wrongChat(chatName, currentTitleForDisplay(window))
        }

        guard let input = findAll(window, where: { role($0) == kAXTextAreaRole }).first else { throw SendError.noInput }
        return (app, window, input)
    }

    /// 把 text 发到名为 chatName 的聊天。发之前已核对过聊天名。
    @MainActor
    static func send(_ text: String, toChatNamed chatName: String) async throws {
        let (app, window, input) = try await openVerified(chatName)

        // 3. 填输入框（已有草稿就不动，免得覆盖用户自己打的字）
        let existing = (attr(input, kAXValueAttribute) as? String) ?? ""
        guard existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SendError.draftNotEmpty }
        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, text as CFString)
        try await Task.sleep(for: .milliseconds(400))

        // 4. 点「发送」
        try await pressSend(app: app, window: window, input: input)
    }

    /// 发文件：核对聊天 → 文件放进剪贴板 → 在 WhatsApp 输入框粘贴（⌘V）→ 出现预览后点「发送」。
    /// 发完把用户原来剪贴板里的东西放回去。
    @MainActor
    static func sendFiles(_ urls: [URL], toChatNamed chatName: String) async throws {
        let (app, window, input) = try await openVerified(chatName)
        let existing = (attr(input, kAXValueAttribute) as? String) ?? ""
        guard existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SendError.draftNotEmpty }

        // 暂存剪贴板
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        defer {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])

        app.activate()
        try await Task.sleep(for: .milliseconds(400))
        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .milliseconds(200))
        pressCommandV()

        // 最多等 10 秒：出现文件预览（底部有「发送」按钮）
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        func previewSendButton() -> AXUIElement? {
            let windows = (attr(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? [window]
            for w in windows {
                if let b = findAll(w, where: isPreviewSendButton).first { return b }
            }
            return nil
        }
        var btn: AXUIElement?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(200))
            // 安全：如果粘进去的是文字（文件路径），说明没当成文件，清掉、不发
            let v = ((attr(input, kAXValueAttribute) as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty {
                AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, "" as CFString)
                throw SendError.pasteFailed
            }
            if let b = previewSendButton() { btn = b; break }
        }
        guard var button = btn else { throw SendError.filePreviewNoSend }

        // 预览刚弹出时有动画，太早点会被忽略：等按钮可用、再稳 0.8 秒
        for _ in 0..<10 where (attr(button, kAXEnabledAttribute) as? Bool) == false {
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .milliseconds(800))

        // 点「发送」→ 看预览关没关；没关就再点一次；还不行就在 WhatsApp 里按回车（焦点在配文框，回车 = 发送）
        for attempt in 0..<3 {
            if attempt < 2 {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            } else {
                app.activate()
                try await Task.sleep(for: .milliseconds(300))
                pressReturn()
            }
            for _ in 0..<15 {
                try await Task.sleep(for: .milliseconds(200))
                if previewSendButton() == nil { return }   // 预览关了 = 发出去了
            }
            if let b = previewSendButton() { button = b }
        }
        throw SendError.filePreviewNoSend
    }

    /// 文件预览里的「发送」按钮。2026-11-10 实测：description「\u{200E}发送」，identifier WAMultiSendBottomBarView_SendButton
    private static func isPreviewSendButton(_ el: AXUIElement) -> Bool {
        guard role(el) == kAXButtonRole else { return false }
        let id = attr(el, kAXIdentifierAttribute) as? String ?? ""
        if id == "WAMultiSendBottomBarView_SendButton" { return true }
        if id.isEmpty || id.hasPrefix("MultiSend") || id.hasPrefix("WAMultiSend") || id.hasPrefix("CaptionBar") {
            return ["发送", "send", "enviar"].contains(norm(desc(el)).lowercased())
        }
        return false
    }

    private static func pressCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }

    /// 给一个手机号发消息（可以是从没聊过的人）：用 WhatsApp 官方链接 whatsapp://send 打开聊天并预填文字，再点「发送」。
    /// digits：只含数字、带国家码，如 34600123456。
    /// 安全：只有确认 WhatsApp 输入框里出现的正是这段文字时才点发送；号码打不开时原来的聊天不受影响。
    @MainActor
    static func send(_ text: String, toPhone digits: String) async throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw SendError.notRunning
        }
        guard hasPermission else { throw SendError.noPermission }
        let enc: (String) -> String = {
            $0.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? $0
        }
        guard let url = URL(string: "whatsapp://send?phone=\(digits)&text=\(enc(text))"),
              NSWorkspace.shared.open(url) else { throw SendError.phoneNotOpened }

        // 最多等 8 秒：输入框里出现这段文字，说明聊天已打开
        let want = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(200))
            guard let window = (attr(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first(where: { w in
                findAll(w, where: { role($0) == kAXTextAreaRole }).first != nil
            }), let input = findAll(window, where: { role($0) == kAXTextAreaRole }).first else { continue }
            let v = ((attr(input, kAXValueAttribute) as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if v == want {
                try await Task.sleep(for: .milliseconds(300))
                try await pressSend(app: app, window: window, input: input)
                return
            }
        }
        throw SendError.phoneNotOpened
    }

    /// 点「发送」按钮；找不到就切到 WhatsApp 按回车
    @MainActor
    private static func pressSend(app: NSRunningApplication, window: AXUIElement, input: AXUIElement) async throws {
        let sendNames: Set<String> = ["发送", "send", "enviar"]
        for _ in 0..<5 {
            if let btn = findAll(window, where: { role($0) == kAXButtonRole && sendNames.contains(norm(desc($0)).lowercased()) }).first {
                AXUIElementPerformAction(btn, kAXPressAction as CFString)
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        app.activate()
        try await Task.sleep(for: .milliseconds(300))
        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        pressReturn()
        try await Task.sleep(for: .milliseconds(300))
    }

    /// 发完把 autoTrans 窗口切回最前面。
    /// macOS 14 起普通的 activate() 是「请求」，别的程序在前台时可能被忽略；
    /// 所以再用辅助功能把自己设为最前（有「设备控制」权限时一定生效）。
    @MainActor
    static func bringAutoTransToFront() {
        NSApp.activate()
        let me = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetAttributeValue(me, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// 只打开某个聊天（不发消息）
    @MainActor
    static func openChat(named chatName: String) throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { throw SendError.notRunning }
        guard hasPermission else { throw SendError.noPermission }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = (attr(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first else { throw SendError.noWindow }
        let want = norm(chatName)
        guard let row = findAll(window, where: { role($0) == kAXButtonRole && norm(desc($0)) == want }).first else {
            throw SendError.chatNotFound(chatName)
        }
        AXUIElementPerformAction(row, kAXPressAction as CFString)
    }

    // MARK: 诊断：打印 autoTrans 看到的 WhatsApp 界面（autoTrans --ax-dump）
    enum AppState: Equatable {
        case notRunning      // 没打开
        case noWindow        // 开着但窗口关了
        case notLoggedIn     // 窗口里看不到聊天列表（多半停在扫码登录页）
        case ready
        case unknown         // 没有辅助功能权限，看不了界面，只知道它在运行
    }

    /// WhatsApp 是否打开并已登录：窗口里能看到至少一个聊天（左侧列表按钮或右侧当前聊天）就算已登录
    @MainActor
    static func appState(knownChats: [String]) -> AppState {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              !app.isTerminated else { return .notRunning }
        guard hasPermission else { return .unknown }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = attr(axApp, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else { return .noWindow }
        let names = Set(knownChats.prefix(40).map(norm))
        for w in windows {
            if openChatTitles(w).contains(where: { names.contains($0) }) { return .ready }
            if !findAll(w, where: { role($0) == kAXButtonRole && names.contains(norm(desc($0))) }).isEmpty { return .ready }
        }
        return .notLoggedIn
    }

    /// WhatsApp 现在有几个窗口（很便宜，可以每次轮询都查）；没权限或没运行返回 nil
    @MainActor
    static func windowCount() -> Int? {
        guard hasPermission,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        return (attr(axApp, kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0
    }

    static func launchWhatsApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    /// 诊断：列出 WhatsApp 所有窗口里的按钮（描述 / 标题 / 帮助 / 标识 / 是否可用 / 深度），不限数量
    static func dumpButtons() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { print("WhatsApp 没运行"); return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let wins = (attr(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for (wi, w) in wins.enumerated() {
            var queue: [(AXUIElement, Int)] = [(w, 0)]
            var visited = 0
            while !queue.isEmpty {
                let (el, d) = queue.removeFirst(); visited += 1
                let r = role(el)
                if r == kAXButtonRole || r == "AXSheet" || r == "AXDialog" || r == kAXTextAreaRole || r == kAXTextFieldRole {
                    let t = attr(el, kAXTitleAttribute) as? String ?? ""
                    let h = attr(el, kAXHelpAttribute) as? String ?? ""
                    let i = attr(el, "AXIdentifier") as? String ?? ""
                    let en = (attr(el, kAXEnabledAttribute) as? Bool).map { $0 ? "" : " [不可用]" } ?? ""
                    print("win\(wi) #\(visited) d\(d) \(r) desc=「\(desc(el))」 title=「\(t)」 help=「\(h)」 id=「\(i)」\(en)")
                }
                if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids.map { ($0, d + 1) }) }
            }
            print("win\(wi)：共 \(visited) 个元素")
        }
    }

    static func dump() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { print("WhatsApp 没运行"); return }
        print("trusted:", hasPermission)
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        if CommandLine.arguments.contains("--manual") {
            print("set AXManualAccessibility:", AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue)
            print("set AXEnhancedUserInterface:", AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue)
            Thread.sleep(forTimeInterval: 1)
        }
        let wins = (attr(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        if let w = wins.first { print("open chat names:", openChatTitles(w), "display:", currentTitleForDisplay(w)) }
        print("windows:", wins.count, wins.map { attr($0, kAXTitleAttribute) as? String ?? "?" })
        for (wi, w) in wins.enumerated() {
            var roles: [String: Int] = [:]
            var visited = 0
            var queue: [(AXUIElement, Int)] = [(w, 0)]
            var maxDepth = 0
            while !queue.isEmpty, visited < 20000 {
                let (el, d) = queue.removeFirst(); visited += 1; maxDepth = max(maxDepth, d)
                let r = role(el); roles[r, default: 0] += 1
                if CommandLine.arguments.contains("--tree") { print(String(repeating: "  ", count: d) + r + " [" + desc(el) + "] kids=" + String(((attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []).count)) }
                if false {
                    var names: CFArray?
                    AXUIElementCopyAttributeNames(el, &names)
                    for n in (names as? [String]) ?? [] {
                        if let v = attr(el, n) { let sv = String(describing: v); if sv.count < 120 { print("      \(n) = \(sv)") } else { print("      \(n) = (long)") } }
                    }
                    let kids = (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
                    print("      children:", kids.map { "\(role($0)):\(desc($0)):\(attr($0, kAXValueAttribute) as? String ?? "")" })
                }
                if r == "AXHeading" || r == kAXTextAreaRole { print("  win\(wi) d\(d) \(r) desc=\(desc(el)) title=\(attr(el, kAXTitleAttribute) as? String ?? "") value=\(String(describing: attr(el, kAXValueAttribute)).prefix(40))") }
                if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids.map { ($0, d + 1) }) }
            }
            print("win\(wi): visited \(visited), maxDepth \(maxDepth), roles:", roles.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
    }

    // MARK: 辅助

    /// 去掉看不见的方向符号、空格、逗号，用来比较聊天名（号码在界面里会被拆成「+ 3 4,6 3 2,…」）
    static func norm(_ s: String) -> String {
        let drop: Set<Character> = ["\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                                    "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", ","]
        return String(s.filter { !drop.contains($0) && !$0.isWhitespace })
    }

    /// 右侧当前打开的是哪个聊天。WhatsApp 不同版本放的位置不同，几处都看：
    /// - 消息区：AXGroup「与张三的聊天消息」（2026-11-10 实测）
    /// - 右上角按钮：「向张三发起视频通话 / 语音通话」（群聊可能没有）
    /// - 早先实测过的：AXHeading「张三」
    private static func openChatTitles(_ window: AXUIElement) -> [String] {
        let patterns = [#"^与(.+)的聊天消息$"#, #"^向(.+)发起(视频|语音)通话$"#,
                        #"^(?i)messages in chat with (.+)$"#, #"^(?i)(?:video|voice) call (.+)$"#]
        var out: [String] = []
        for el in findAll(window, where: { [kAXGroupRole, kAXButtonRole, "AXHeading"].contains(role($0)) }) {
            let d = desc(el).filter { !"\u{200E}\u{200F}\u{2068}\u{2069}".contains($0) }
            if role(el) == "AXHeading" { out.append(norm(d)); continue }
            for p in patterns {
                if let r = d.range(of: p, options: .regularExpression),
                   let m = try? NSRegularExpression(pattern: p).firstMatch(in: String(d[r]), range: NSRange(location: 0, length: d[r].utf16.count)),
                   let g = Range(m.range(at: 1), in: String(d[r])) {
                    out.append(norm(String(String(d[r])[g])))
                }
            }
        }
        return out.filter { !$0.isEmpty }
    }

    /// 报错时给人看：当前打开的聊天名
    private static func currentTitleForDisplay(_ window: AXUIElement) -> String {
        let skip: Set<String> = ["聊天", "更多", "今天", "昨天"]
        return openChatTitles(window).first { !skip.contains($0) && !$0.contains("月") } ?? "（看不出来）"
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    private static func role(_ el: AXUIElement) -> String { attr(el, kAXRoleAttribute) as? String ?? "" }
    private static func desc(_ el: AXUIElement) -> String { attr(el, kAXDescriptionAttribute) as? String ?? "" }

    /// 广度优先遍历界面元素
    private static func findAll(_ root: AXUIElement, where pred: (AXUIElement) -> Bool) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 6000 {
            let el = queue.removeFirst()
            visited += 1
            if pred(el) { out.append(el) }
            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return out
    }

    private static func pressReturn() {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
