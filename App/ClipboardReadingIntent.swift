import AppIntents
import SwiftUI

/// One active shortcut invocation owns playback. Every control carries its session ID.
@MainActor
final class ShortcutReadingSession {
    static let shared = ShortcutReadingSession()
    private(set) var id: String?
    private(set) var model: PlayerModel?

    func begin(text: String, player: PlayerModel? = nil) throws -> String {
        guard id == nil else { throw ReaderError.configuration("已有朗读弹窗，请先关闭它再运行快捷指令。") }
        let next = UUID().uuidString
        id = next
        model = player ?? PlayerModel(text: text)
        return next
    }

    func require(_ expected: String) throws -> PlayerModel {
        guard id == expected, let model else {
            throw ReaderError.configuration("这次朗读已经结束，请重新运行快捷指令。")
        }
        return model
    }

    /// Each accepted system confirmation means one replay of the existing player.
    /// Cancellation propagates to perform()'s defer, which owns closing the session.
    func repeatUntilClosed(_ expected: String, confirm: (String) async throws -> Void) async throws {
        while true {
            try Task.checkCancellation()
            _ = try require(expected)
            let presentationID = UUID().uuidString
            try await confirm(presentationID)
            try Task.checkCancellation()
            let player = try require(expected)
            player.replay()
            if let error = player.errorMessage { throw ReaderError.invalidAudio(error) }
        }
    }

    func end(_ expected: String) {
        guard id == expected else { return }
        model?.close()
        model = nil
        id = nil
    }
}

@available(iOS 26.0, *)
struct ReadCopiedTextIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "直接朗读文本"
    static let description = IntentDescription("直接朗读传入文本，并在浮窗显示正文。用于复制后的控制中心快捷指令。")
    static let openAppWhenRun = false

    @Parameter(title: "文本") var text: String
    static var parameterSummary: some ParameterSummary { Summary("朗读 \(\.$text)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReaderError.invalidText("剪贴板没有文字。请先复制需要朗读的英文，再运行快捷指令。")
        }
        let validated = try SelectionText.validate(text)
        try Task.checkCancellation()
        let session = ShortcutReadingSession.shared
        let id = try session.begin(text: validated)
        defer { session.end(id) }
        try await session.require(id).startAndWait()
        try await session.repeatUntilClosed(id) { presentationID in
            try await requestConfirmation(
                actionName: .custom(acceptLabel: "重复播放", acceptAlternatives: [], denyLabel: "关闭", denyAlternatives: []),
                showDialogAsPrompt: false,
                snippetIntent: ReadingPlaybackSnippetIntent(sessionID: id, presentationID: presentationID))
        }
        return .result()
    }
}

@available(iOS 26.0, *)
struct ReadingPlaybackSnippetIntent: SnippetIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "朗读播放器"
    static let isDiscoverable = false
    @Parameter(title: "会话") var sessionID: String
    // Distinguishes successive confirmations without adding a visible counter.
    @Parameter(title: "呈现标识") var presentationID: String
    init() {}
    init(sessionID: String, presentationID: String) {
        self.sessionID = sessionID
        self.presentationID = presentationID
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let model = try ShortcutReadingSession.shared.require(sessionID)
        // Rendering is read-only. The two actions are supplied by the system footer.
        return .result(view: Text(model.text).fixedSize(horizontal: false, vertical: true).padding())
    }
}
