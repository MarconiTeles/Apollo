import AppKit
import ReviewKit

enum StandaloneReviewLauncher {
    private static var helperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/Apollo Review.app")
    }

    static func open(
        params: OpenReviewParams,
        acknowledgement: ReviewCompletionAcknowledgement?
    ) {
        guard let deepLink = params.deepLink() else { return }
        guard var components = URLComponents(url: deepLink,
                                             resolvingAgainstBaseURL: false)
        else { return }
        if let acknowledgement {
            var items = components.queryItems ?? []
            items += [
                .init(name: "ackTaskId", value: acknowledgement.taskId),
                .init(name: "ackPendingAttachmentId", value: acknowledgement.activeAtt),
            ]
            components.queryItems = items
        }
        guard let launchURL = components.url else { return }
        launch(url: launchURL)
    }

    static func open(savedJSON: Data) {
        launch(arguments: ["--saved-review", ReviewHandoff.encode(savedJSON)])
    }

    private static func launch(arguments: [String]) {
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            presentFailure("Apollo Review não está incluído nesta build.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, error in
            if let error {
                DispatchQueue.main.async {
                    presentFailure("Não foi possível abrir o Apollo Review: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Deliver real review identity as an open-URL Apple event.
    ///
    /// `NSWorkspace.OpenConfiguration.arguments` is only process-launch
    /// metadata and macOS may omit it when opening/reusing a GUI application.
    /// That produced a valid Apollo Review window with an empty
    /// `LaunchConfiguration` ("Sem arquivo"). Targeted URL opening is the
    /// native document/deep-link contract and reaches both a fresh helper and
    /// an already-running helper through `application(_:open:)`.
    private static func launch(url: URL) {
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            presentFailure("Apollo Review não está incluído nesta build.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: helperURL,
            configuration: configuration
        ) { _, error in
            if let error {
                DispatchQueue.main.async {
                    presentFailure("Não foi possível abrir o Apollo Review: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Apollo Review"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
