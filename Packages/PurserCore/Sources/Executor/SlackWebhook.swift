import Foundation

public enum SlackPublishError: Error, Equatable, Sendable {
    case invalidWebhook
    case http(Int)
}

/// The only webhook shape Purser posts to. The URL is a secret: Keychain only, never logged or audited.
public enum SlackWebhook {
    public static func isValid(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "hooks.slack.com"
    }
}
