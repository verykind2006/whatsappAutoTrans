import Foundation
import SQLite3

/// 一个聊天（单聊或群聊）
struct Chat: Identifiable, Hashable {
    let id: Int          // ZWACHATSESSION.Z_PK
    let name: String
    let isGroup: Bool
    let lastDate: Date
}

/// 一条消息
struct Message: Identifiable, Hashable {
    enum Kind { case text, image, video, audio, document, link, other }
    let id: Int          // ZWAMESSAGE.Z_PK，自增，可当游标
    let chatID: Int
    let isFromMe: Bool
    let sender: String?  // 群聊里谁说的；单聊为 nil
    let date: Date
    let kind: Kind
    let text: String     // 文字内容（图片说明、文件名等也放这里）
    var mediaPath: String? = nil  // 图片/语音在本机的完整路径；WhatsApp 还没下载的为 nil

    /// 语音消息：把识别出的文字放进 text，后面的翻译、显示、通知都照文字消息处理
    func withTranscript(_ t: String) -> Message {
        Message(id: id, chatID: chatID, isFromMe: isFromMe, sender: sender, date: date,
                kind: kind, text: t, mediaPath: mediaPath)
    }

    /// 需要翻译的：有文字、不是中文、不只是链接/表情/数字
    var needsTranslation: Bool {
        guard kind == .text || kind == .link || kind == .image || kind == .video || kind == .audio else { return false }
        return LanguageGuess.isForeign(text)
    }
}

enum DBError: Error, LocalizedError {
    case cannotOpen(String)
    var errorDescription: String? {
        switch self { case .cannotOpen(let m): return m }
    }
}

/// 只读访问 WhatsApp 桌面版的聊天数据库。每次查询都新开连接，读完就关，不长期占用。
final class WhatsAppDB {
    static let defaultPath = NSHomeDirectory()
        + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
    let path: String
    init(path: String = WhatsAppDB.defaultPath) { self.path = path }

    private static let appleEpoch: Double = 978_307_200

    private func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let uri = "file:" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?mode=ro"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(db)
            throw DBError.cannotOpen(msg)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        return try body(db)
    }

    private func query(_ db: OpaquePointer, _ sql: String, _ args: [Int] = [],
                       row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), Int64(a)) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt) }
            else if rc == SQLITE_DONE { break }
            else { throw DBError.cannotOpen(String(cString: sqlite3_errmsg(db))) }
        }
    }

    private static func str(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }

    /// 显示名里常夹着看不见的方向控制符（‪ ‬ ⁦ ⁩），去掉
    static func clean(_ s: String) -> String {
        let bad: Set<Character> = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                                   "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{200E}", "\u{200F}"]
        return String(s.filter { !bad.contains($0) }).trimmingCharacters(in: .whitespaces)
    }

    /// 媒体路径在库里是相对的（Media/…），相对于 …shared/Message/；文件不存在就当没有
    static func mediaPath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let full = raw.hasPrefix("/") ? raw
            : (defaultPath as NSString).deletingLastPathComponent + "/Message/" + raw
        return FileManager.default.fileExists(atPath: full) ? full : nil
    }

    /// 能不能打开（用来判断有没有「完全磁盘访问权限」）
    func canOpen() -> Bool {
        (try? withDB { db in try query(db, "select 1 from ZWAMESSAGE limit 1") { _ in } }) != nil
    }

    func maxMessageID() throws -> Int {
        try withDB { db in
            var v = 0
            try query(db, "select max(Z_PK) from ZWAMESSAGE") { v = Int(sqlite3_column_int64($0, 0)) }
            return v
        }
    }

    /// 每个聊天里对方发来的最新一条消息编号（不含系统消息）
    func latestIncomingByChat() throws -> [Int: Int] {
        try withDB { db in
            var out: [Int: Int] = [:]
            try query(db, """
                select ZCHATSESSION, max(Z_PK) from ZWAMESSAGE
                where ZISFROMME = 0 and ZMESSAGETYPE not in (6, 10) group by ZCHATSESSION
                """) { s in out[Int(sqlite3_column_int64(s, 0))] = Int(sqlite3_column_int64(s, 1)) }
            return out
        }
    }

    /// 某聊天里编号大于 afterID 的「我发的」文字消息（用来确认真的发出去了）
    func outgoingTexts(chatID: Int, after afterID: Int) throws -> [(id: Int, text: String)] {
        try withDB { db in
            var out: [(id: Int, text: String)] = []
            try query(db, """
                select Z_PK, ZTEXT from ZWAMESSAGE
                where ZCHATSESSION = ? and ZISFROMME = 1 and Z_PK > ? and ZTEXT is not null
                """, [chatID, afterID]) { s in out.append((Int(sqlite3_column_int64(s, 0)), Self.str(s, 1) ?? "")) }
            return out
        }
    }

    /// 所有聊天里编号大于 afterID 的「我发的」文字消息（新建聊天发送后，用来找它落在哪个聊天）
    func outgoingTextsAnyChat(after afterID: Int) throws -> [(id: Int, chatID: Int, text: String)] {
        try withDB { db in
            var out: [(id: Int, chatID: Int, text: String)] = []
            try query(db, """
                select Z_PK, ZCHATSESSION, ZTEXT from ZWAMESSAGE
                where ZISFROMME = 1 and Z_PK > ? and ZTEXT is not null
                """, [afterID]) { s in
                out.append((Int(sqlite3_column_int64(s, 0)), Int(sqlite3_column_int64(s, 1)), Self.str(s, 2) ?? ""))
            }
            return out
        }
    }

    /// 编号大于 minID 的、对方发来的消息：(聊天, 消息编号)
    func incomingMessages(after minID: Int) throws -> [(Int, Int)] {
        try withDB { db in
            var out: [(Int, Int)] = []
            try query(db, """
                select ZCHATSESSION, Z_PK from ZWAMESSAGE
                where ZISFROMME = 0 and ZMESSAGETYPE not in (6, 10) and Z_PK > ?
                """, [minID]) { s in out.append((Int(sqlite3_column_int64(s, 0)), Int(sqlite3_column_int64(s, 1)))) }
            return out
        }
    }

    /// 每个聊天的最后一条消息（左侧列表第二行预览用）
    func lastMessages() throws -> [Int: Message] {
        try withDB { db in
            var out: [Int: Message] = [:]
            try query(db, """
                select m.Z_PK, m.ZCHATSESSION, m.ZISFROMME, m.ZMESSAGEDATE, m.ZMESSAGETYPE, m.ZTEXT
                from ZWAMESSAGE m
                join (select max(Z_PK) as pk from ZWAMESSAGE where ZMESSAGETYPE not in (6, 10)
                      group by ZCHATSESSION) last on last.pk = m.Z_PK
                """) { s in
                let chat = Int(sqlite3_column_int64(s, 1))
                let kind: Message.Kind
                switch Int(sqlite3_column_int64(s, 4)) {
                case 0: kind = .text
                case 1: kind = .image
                case 2: kind = .video
                case 3: kind = .audio
                case 7: kind = .link
                case 8: kind = .document
                default: kind = .other
                }
                out[chat] = Message(id: Int(sqlite3_column_int64(s, 0)), chatID: chat,
                                    isFromMe: sqlite3_column_int64(s, 2) == 1, sender: nil,
                                    date: Date(timeIntervalSince1970: sqlite3_column_double(s, 3) + Self.appleEpoch),
                                    kind: kind, text: Self.str(s, 5) ?? "")
            }
            return out
        }
    }

    /// 聊天列表：单聊(0) + 群聊(1)，去掉状态广播(2)、隐藏、已删除；按最后消息时间倒序
    func chats() throws -> [Chat] {
        try withDB { db in
            var out: [Chat] = []
            try query(db, """
                select Z_PK, ZSESSIONTYPE, ZPARTNERNAME, ZLASTMESSAGEDATE
                from ZWACHATSESSION
                where ZSESSIONTYPE in (0,1) and ifnull(ZHIDDEN,0)=0 and ifnull(ZREMOVED,0)=0
                order by ZLASTMESSAGEDATE desc
                """) { s in
                let name = Self.clean(Self.str(s, 2) ?? "")
                out.append(Chat(id: Int(sqlite3_column_int64(s, 0)),
                                name: name.isEmpty ? "（无名聊天）" : name,
                                isGroup: sqlite3_column_int64(s, 1) == 1,
                                lastDate: Date(timeIntervalSince1970: sqlite3_column_double(s, 3) + Self.appleEpoch)))
            }
            return out
        }
    }

    /// 某个聊天最近 limit 条消息（按时间正序返回）
    func messages(chatID: Int, limit: Int = 40) throws -> [Message] {
        try withDB { db in
            var out: [Message] = []
            // 群聊发送人：优先用对方自己设的昵称(ZWAPROFILEPUSHNAME)，其次通讯录名
            try query(db, """
                select m.Z_PK, m.ZISFROMME, m.ZMESSAGEDATE, m.ZMESSAGETYPE, m.ZTEXT,
                       m.ZGROUPMEMBER, p.ZPUSHNAME, g.ZCONTACTNAME, i.ZMEDIALOCALPATH
                from ZWAMESSAGE m
                left join ZWAMEDIAITEM i on i.Z_PK = m.ZMEDIAITEM
                left join ZWAGROUPMEMBER g on g.Z_PK = m.ZGROUPMEMBER
                left join ZWAPROFILEPUSHNAME p on p.ZJID = g.ZMEMBERJID
                where m.ZCHATSESSION = ? and m.ZMESSAGETYPE not in (6, 10)
                order by m.Z_PK desc limit ?
                """, [chatID, limit]) { s in
                let type = Int(sqlite3_column_int64(s, 3))
                let kind: Message.Kind
                switch type {
                case 0: kind = .text
                case 1: kind = .image
                case 2: kind = .video
                case 3: kind = .audio
                case 7: kind = .link
                case 8: kind = .document
                default: kind = .other
                }
                let memberPK = sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, 5))
                var sender: String? = nil
                if let memberPK {
                    let n = Self.clean(Self.str(s, 6) ?? Self.str(s, 7) ?? "")
                    sender = n.isEmpty ? "群成员\(memberPK)" : n
                }
                out.append(Message(id: Int(sqlite3_column_int64(s, 0)),
                                   chatID: chatID,
                                   isFromMe: sqlite3_column_int64(s, 1) == 1,
                                   sender: sender,
                                   date: Date(timeIntervalSince1970: sqlite3_column_double(s, 2) + Self.appleEpoch),
                                   kind: kind,
                                   text: Self.str(s, 4) ?? "",
                                   mediaPath: Self.mediaPath(Self.str(s, 8))))
            }
            return out.reversed()
        }
    }
}

/// 粗略判断一段文字是不是「外语」：汉字少、拉丁字母多就算外语
enum LanguageGuess {
    static func isForeign(_ text: String) -> Bool {
        var han = 0, letters = 0
        // 去掉网址，免得链接里的字母被当成外语
        let stripped = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        for u in stripped.unicodeScalars {
            if (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) { han += 1 }
            else if u.properties.isAlphabetic { letters += 1 }
        }
        // 有 4 个以上汉字就算中文消息（比如中文里夹着西语地址，地址本来也不该翻）
        return han < 4 && letters >= 2 && letters > han * 2
    }
}
