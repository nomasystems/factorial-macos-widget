import Foundation
import os

private let logger = Logger(subsystem: "com.factorial.widget", category: "TokenStore")

struct OAuthTokens: Codable {
    var access_token: String?
    var refresh_token: String?
    var token_type: String?
    var expires_in: Int?
}

class TokenStore {
    static let shared = TokenStore()

    private let tokenFile: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        tokenFile = home.appendingPathComponent(".factorial-tokens.json")
    }

    func load() -> OAuthTokens {
        guard let data = try? Data(contentsOf: tokenFile),
              let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else {
            return OAuthTokens()
        }
        return tokens
    }

    func save(_ tokens: OAuthTokens) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(tokens)
            try data.write(to: tokenFile, options: .atomic)
        } catch {
            logger.error("Failed to save tokens: \(error.localizedDescription, privacy: .public)")
        }
    }
}
