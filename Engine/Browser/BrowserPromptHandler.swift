import Foundation

public protocol BrowserPromptProviding: AnyObject, Sendable {
    func prompt(
        message: String,
        defaultText: String?,
        frameURL: URL?,
        completionHandler: @escaping @Sendable (String?) -> Void
    )
}

public final class BrowserPromptHandler: @unchecked Sendable {
    public static let shared = BrowserPromptHandler()

    public weak var provider: BrowserPromptProviding?

    public init(provider: BrowserPromptProviding? = nil) {
        self.provider = provider
    }

    public func handlePrompt(
        prompt: String,
        defaultText: String?,
        frameURL: URL?,
        completionHandler: @escaping @Sendable (String?) -> Void
    ) {
        guard let provider else {
            // Default must strictly be cancellation (nil). Never silently submit prompt text.
            completionHandler(nil)
            return
        }
        provider.prompt(
            message: prompt,
            defaultText: defaultText,
            frameURL: frameURL,
            completionHandler: completionHandler
        )
    }
}
