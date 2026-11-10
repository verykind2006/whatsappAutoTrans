import Foundation

/// API key 存在本机文件 ~/Library/Application Support/autoTrans/keys.json（不在 OneDrive 里）。
/// 文件权限 600：只有当前登录用户能读写。按服务商区分（如 anthropic-api-key）。
/// 不用钥匙串，是因为每次重新编译后读钥匙串都会弹窗要密码（用户 2026-11-10 要求）。
enum KeyStore {
    static let dir = NSHomeDirectory() + "/Library/Application Support/autoTrans"
    static let path = dir + "/keys.json"

    private static func load() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    static func readKey(account: String) -> String? {
        guard let k = load()[account]?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return nil }
        return k
    }

    @discardableResult
    static func saveKey(_ key: String, account: String) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var dict = load()
            dict[account] = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let data = try JSONEncoder().encode(dict)
            // 先建空文件并设 600，再写内容，避免出现短暂可被别人读的窗口
            if !fm.fileExists(atPath: path) {
                fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try data.write(to: URL(fileURLWithPath: path))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch { return false }
    }
}
