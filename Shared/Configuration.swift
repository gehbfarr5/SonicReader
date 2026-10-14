import Foundation

struct ReaderConfiguration {
    static let modelID = "sonic-3.6"
    static let apiVersion = "2026-08-14"
    static let voiceID = "47c38ca4-5f35-497b-b1a3-415245fb35e1"
    static let rates: [Float] = [0.8, 0.9, 1.0, 1.1, 1.2]
    static let maximumCharacters = 4000
    static let example = "Small steps every day lead to meaningful progress."

    static func appGroup() throws -> String {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "SonicAppGroup") as? String,
              group.hasPrefix("group."), !group.contains("$(") else {
            throw ReaderError.configuration("安装包缺少共享存储配置。请重新打包。")
        }
        return group
    }

    static func sharedRoot() throws -> URL {
        let group = try appGroup()
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw ReaderError.configuration("共享存储权限不可用。请检查签名是否为主 App 和分享扩展保留了同一个 App Group。")
        }
        return url.appendingPathComponent("SonicReader", isDirectory: true)
    }
}

enum ReaderError: LocalizedError {
    case configuration(String), invalidText(String), invalidAudio(String), http(Int), emptySelection, missingKey, keychain(Int32)

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .invalidText(let message), .invalidAudio(let message): return message
        case .emptySelection: return "没有收到所选文字。请从文字选区菜单中点“分享”，再选择“英文随听”。"
        case .missingKey: return "请先在设置中输入 Cartesia API 密钥。"
        case .keychain(let status): return "密钥存储不可用（\(status)）。请检查 App Group 签名权限。"
        case .http(let code):
            switch code {
            case 401, 403: return "Cartesia 拒绝了请求（\(code)）。请检查密钥及账户权限。"
            case 402: return "Cartesia 账户额度不足，请检查账户余额。"
            case 429: return "请求过于频繁或额度已用完。请稍后重试并检查 Cartesia 用量。"
            default: return "Cartesia 返回错误（\(code)）。本次没有保存音频，请重试。"
            }
        }
    }
}

struct SelectionText {
    static func validate(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReaderError.emptySelection }
        guard trimmed.count <= ReaderConfiguration.maximumCharacters else {
            throw ReaderError.invalidText("一次最多朗读 \(ReaderConfiguration.maximumCharacters) 个字符。请缩小选区。")
        }
        if !trimmed.contains(where: { $0.isWhitespace }),
           let url = URL(string: trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            throw ReaderError.invalidText("收到的是网页链接。请选中具体英文，再从选区菜单中分享。")
        }
        return trimmed
    }
}
