import SwiftUI
import UIKit

private struct PlaybackSelection: Identifiable {
    let id = UUID()
    let text: String
    let record: ListeningRecord?
}

struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var activeSwipeID: String?
    @State private var records: [ListeningRecord] = []
    @State private var draft = ReaderConfiguration.example
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var showShare = false
    @State private var selection: PlaybackSelection?
    @ScaledMetric(relativeTo: .body) private var historyRowHeight = 108.0
    @ScaledMetric(relativeTo: .body) private var historyTextHeight = 46.0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("看一句，听懂一句", systemImage: "waveform").font(.title2.weight(.semibold)).foregroundStyle(.teal)
                        Text("在 ChatGPT、Safari 或其他 App 中选中英文，点选区菜单的“分享”，选择“英文随听”。播放器关闭后回到原来的阅读界面。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Section("试读一句") {
                    TextEditor(text: $draft).frame(minHeight: 90).accessibilityIdentifier("draftText")
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 12) { trialActions }
                    } else {
                        HStack(spacing: 12) { trialActions }
                    }
                }
                Section {
                    if records.isEmpty {
                        ContentUnavailableView("还没有听过的内容", systemImage: "text.book.closed", description: Text("成功生成的原文和音频会自动保存在这里。"))
                    } else {
                        ForEach(records) { record in
                            HistoryRow(record: record, height: historyRowHeight, textHeight: historyTextHeight,
                                       activeSwipeID: $activeSwipeID,
                                       onPlay: { selection = PlaybackSelection(text: record.text, record: record) },
                                       onDelete: { delete(record) },
                                       onToggleFavorite: { toggleFavorite(record) })
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                    }
                } header: { HStack { Text("听过的内容"); Spacer(); Text("\(records.count) / 500 条") } }
            }
            .navigationTitle("英文随听")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置").accessibilityIdentifier("homeSettings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showShare, onDismiss: refresh) { SystemShareSheet(text: draft) }
            .sheet(item: $selection, onDismiss: refresh) { item in
                PlayerView(model: PlayerModel(text: item.text, record: item.record)) { selection = nil }
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .alert("无法完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .onAppear { refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        }.tint(.teal)
    }

    @ViewBuilder
    private var trialActions: some View {
        Button { openDraft() } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill").accessibilityHidden(true)
                Text("开始朗读")
            }
        }
        .buttonStyle(TrialActionStyle(isPrimary: true))
        .accessibilityIdentifier("readDraftButton")

        Button { shareDraft() } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up").accessibilityHidden(true)
                Text("分享试读")
            }
        }
        .buttonStyle(TrialActionStyle(isPrimary: false))
        .accessibilityLabel("测试分享入口")
        .accessibilityIdentifier("shareExampleButton")
    }

    private func refresh() {
        do { records = try HistoryStore(root: ReaderConfiguration.sharedRoot()).list() }
        catch { errorMessage = error.localizedDescription }
    }
    private func openDraft() {
        do { selection = PlaybackSelection(text: try SelectionText.validate(draft), record: nil) }
        catch { errorMessage = error.localizedDescription }
    }
    private func shareDraft() {
        do { draft = try SelectionText.validate(draft); showShare = true }
        catch { errorMessage = error.localizedDescription }
    }
    private func delete(_ record: ListeningRecord) {
        do { try HistoryStore(root: ReaderConfiguration.sharedRoot()).delete(record); refresh() }
        catch { errorMessage = error.localizedDescription }
    }
    private func toggleFavorite(_ record: ListeningRecord) {
        do {
            try HistoryStore(root: ReaderConfiguration.sharedRoot()).setFavorite(record, to: !record.isFavorite)
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

}

struct SystemShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct TrialActionStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .center)
            .foregroundStyle(isPrimary ? Color.white : Color.teal)
            .background(isPrimary ? Color.teal : Color.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isPrimary ? Color.clear : Color.teal.opacity(0.18), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
