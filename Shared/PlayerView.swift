import SwiftUI

struct PlayerView: View {
    @StateObject var model: PlayerModel
    let onClose: () -> Void
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("英文随听").font(.headline)
                    Text("Daniel · Sonic 3.6").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                    .accessibilityLabel("设置").accessibilityIdentifier("playerSettings")
                Button { model.close(); onClose() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("关闭播放器").accessibilityIdentifier("closePlayer")
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("原文").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(model.text).font(.system(.title3, design: .serif)).lineSpacing(7)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("selectedText")
                }
                .padding(24)
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 18) {
                if model.isLoading {
                    HStack { ProgressView(); Text("正在生成语音…").font(.subheadline) }
                        .accessibilityIdentifier("generationProgress")
                } else if let error = model.errorMessage {
                    VStack(spacing: 10) {
                        Text(error).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center)
                            .accessibilityIdentifier("playerError")
                        Button("重试") {
                            if model.duration > 0 { model.togglePlayback() } else { model.start() }
                        }.buttonStyle(.bordered).accessibilityIdentifier("retryGeneration")
                    }
                } else {
                    HStack {
                        Label(model.isPlaying ? "正在播放" : "已暂停", systemImage: model.isPlaying ? "speaker.wave.2" : "pause.circle")
                        Spacer()
                        if model.saved { Label("已保存", systemImage: "checkmark.circle") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("playbackStatus")
                }

                if model.duration > 0 {
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { model.elapsed }, set: { model.seek($0) }), in: 0...model.duration)
                            .tint(.teal).accessibilityLabel("播放进度")
                        HStack {
                            Text(timeString(model.elapsed)); Spacer(); Text(timeString(model.duration))
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 24) {
                    Button { model.replay() } label: {
                        VStack(spacing: 5) { Image(systemName: "backward.end.fill").font(.title2); Text("从头播放").font(.caption) }
                            .frame(width: 80, height: 66)
                    }.accessibilityIdentifier("replayButton")
                    Button { model.togglePlayback() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title).frame(width: 74, height: 74)
                            .background(.teal, in: Circle()).foregroundStyle(.white)
                    }.accessibilityLabel(model.isPlaying ? "暂停" : "播放").accessibilityIdentifier("playPauseButton")
                    Button { model.setLooping(!model.isLooping) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "repeat").font(.title2)
                            Text(model.isLooping ? "循环已开" : "循环关闭").font(.caption)
                        }.frame(width: 80, height: 66)
                    }
                    .foregroundStyle(model.isLooping ? Color.teal : Color.secondary)
                    .accessibilityValue(model.isLooping ? "已开启" : "已关闭").accessibilityIdentifier("loopButton")
                }.disabled(model.duration == 0 || model.isLoading)

                HStack(spacing: 0) {
                    ForEach(ReaderConfiguration.rates, id: \.self) { rate in
                        Button { model.setRate(rate) } label: {
                            Text(String(format: "%.1f×", rate)).font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(model.rate == rate ? Color.teal : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(model.rate == rate ? Color.white : Color.primary)
                        }
                        .accessibilityIdentifier(String(format: "rate-%.1f", rate))
                        .accessibilityValue(model.rate == rate ? "已选择" : "未选择")
                    }
                }.padding(4).background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
            }.padding(20)
        }
        .background(Color(uiColor: .systemBackground))
        .tint(.teal)
        .task { model.start() }
        .onDisappear { model.close() }
        .sheet(isPresented: $showSettings, onDismiss: {
            if model.duration == 0 { model.start() }
        }) { SettingsView() }
    }

    private func timeString(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
