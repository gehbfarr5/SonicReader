import UIKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private var model: PlayerModel?
    private var inputTask: Task<Void, Never>?
    private var hasCompleted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 420, height: 680)
        showLoading()
        inputTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.readSelection()
                try Task.checkCancellation()
                self.showPlayer(text: text)
            } catch is CancellationError {
                // Dismissal cancels input loading.
            } catch { self.showError(error.localizedDescription) }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        inputTask?.cancel()
        model?.close()
    }

    private func readSelection() async throws -> String {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { throw ReaderError.emptySelection }
        var texts: [String] = []
        for item in items {
            var receivedAttachmentText = false
            for provider in item.attachments ?? [] {
                let type: String
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) { type = UTType.plainText.identifier }
                else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) { type = UTType.text.identifier }
                else { continue }
                let text: String = try await withCheckedThrowingContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                        if let error { continuation.resume(throwing: error); return }
                        if let string = value as? String { continuation.resume(returning: string) }
                        else if let attributed = value as? NSAttributedString { continuation.resume(returning: attributed.string) }
                        else if let data = value as? Data, let string = String(data: data, encoding: .utf8) { continuation.resume(returning: string) }
                        else { continuation.resume(throwing: ReaderError.emptySelection) }
                    }
                }
                texts.append(text)
                receivedAttachmentText = true
            }
            if !receivedAttachmentText, let text = item.attributedContentText?.string { texts.append(text) }
        }
        return try SelectionText.validate(texts.joined(separator: "\n\n"))
    }

    private func showPlayer(text: String) {
        let model = PlayerModel(text: text)
        self.model = model
        install(UIHostingController(rootView: PlayerView(model: model) { [weak self] in self?.complete() }))
    }

    private func showLoading() {
        install(UIHostingController(rootView: VStack(spacing: 20) {
            ProgressView("正在读取所选文字…")
            Button("关闭") { [weak self] in self?.complete() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)))
    }

    private func showError(_ message: String) {
        install(UIHostingController(rootView: VStack(spacing: 20) {
            Image(systemName: "text.badge.xmark").font(.largeTitle).foregroundStyle(.teal)
            Text(message).multilineTextAlignment(.center)
            Button("关闭") { [weak self] in self?.complete() }.buttonStyle(.bordered)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)))
    }

    private func install(_ controller: UIViewController) {
        for child in children { child.willMove(toParent: nil); child.view.removeFromSuperview(); child.removeFromParent() }
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
    }

    private func complete() {
        guard !hasCompleted else { return }
        hasCompleted = true
        inputTask?.cancel()
        model?.close()
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
