import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasKey = false
    @State private var storageReady = false
    @State private var message: String?
    @State private var success = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(hasKey ? "密钥已保存" : "尚未配置密钥", systemImage: hasKey ? "checkmark.shield" : "key")
                    SecureField("输入 Cartesia API 密钥", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("apiKeyField")
                    Button("保存密钥") { saveKey() }.disabled(key.isEmpty).accessibilityIdentifier("saveKeyButton")
                    if hasKey { Button("移除密钥", role: .destructive) { removeKey() } }
                } header: { Text("Cartesia API") } footer: {
                    Text("密钥仅存储在本机 Keychain。生成语音时，所选原文会发送给 Cartesia；重复播放和调速使用本地音频。")
                }
                Section("默认声音") {
                    LabeledContent("音色", value: "Daniel · 美式英语")
                    LabeledContent("模型", value: "Sonic 3.6")
                }
                Section("本地历史") {
                    Label(storageReady ? "共享存储可用" : "共享存储待检查", systemImage: storageReady ? "checkmark.circle" : "exclamationmark.triangle")
                    Text("每次成功生成都会保存原文和音频，相同原文直接重播。历史只保存在本机，卸载 App 会删除历史。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message {
                    Section { Text(message).foregroundStyle(success ? Color.teal : Color.red).accessibilityIdentifier("settingsMessage") }
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { checkConfiguration() }
        }.tint(.teal)
    }

    private func checkConfiguration() {
        do {
            _ = try HistoryStore(root: ReaderConfiguration.sharedRoot())
            storageReady = true
            hasKey = try KeyStore(accessGroup: ReaderConfiguration.appGroup()).read() != nil
        } catch { message = error.localizedDescription; success = false }
    }
    private func saveKey() {
        do {
            _ = try HistoryStore(root: ReaderConfiguration.sharedRoot())
            let keys = KeyStore(accessGroup: try ReaderConfiguration.appGroup())
            try keys.save(key)
            guard try keys.read() != nil else { throw ReaderError.missingKey }
            key = ""; hasKey = true; storageReady = true; success = true; message = "密钥已保存。"
        } catch { message = error.localizedDescription; success = false }
    }
    private func removeKey() {
        do {
            try KeyStore(accessGroup: ReaderConfiguration.appGroup()).remove()
            hasKey = false; success = true; message = "密钥已移除。已有音频仍可离线重播。"
        } catch { message = error.localizedDescription; success = false }
    }
}
