import Foundation
import AVFAudio
import Combine

@MainActor
final class PlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var text: String
    @Published private(set) var record: ListeningRecord?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published private(set) var rate: Float = 1.0
    @Published private(set) var isLooping = false
    @Published private(set) var saved = false

    private let store: HistoryStore?
    private let keyStore: KeyStore?
    private let client: CartesiaClient
    private let makePlayer: (URL) throws -> AVAudioPlayer
    private var player: AVAudioPlayer?
    private var loadTask: Task<Void, Never>?
    private var timer: Timer?
    private var interruptionObserver: NSObjectProtocol?
    private var audioSessionActive = false

    init(text: String, record: ListeningRecord? = nil, store: HistoryStore? = nil,
         keyStore: KeyStore? = nil, client: CartesiaClient = CartesiaClient(),
         makePlayer: @escaping (URL) throws -> AVAudioPlayer = { try AVAudioPlayer(contentsOf: $0) }) {
        self.text = text
        self.record = record
        self.store = store
        self.keyStore = keyStore
        self.client = client
        self.makePlayer = makePlayer
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor [weak self] in self?.pause() }
            }
        }
    }

    deinit {
        timer?.invalidate()
        loadTask?.cancel()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func start() {
        guard !isLoading, player == nil else { return }
        errorMessage = nil
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }
            do {
                self.text = try SelectionText.validate(self.text)
                let store: HistoryStore
                if let provided = self.store { store = provided }
                else { store = try HistoryStore(root: ReaderConfiguration.sharedRoot()) }
                var resolved: ListeningRecord
                if let existing = self.record { resolved = existing }
                else if let cached = try store.cached(text: self.text) { resolved = cached }
                else {
                    try store.ensureCanSave(text: self.text)
                    let keys: KeyStore
                    if let provided = self.keyStore { keys = provided }
                    else { keys = KeyStore(accessGroup: try ReaderConfiguration.appGroup()) }
                    guard let key = try keys.read() else { throw ReaderError.missingKey }
                    let audio = try await self.client.synthesize(text: self.text, key: key)
                    try Task.checkCancellation()
                    resolved = try store.save(text: self.text, audio: audio)
                }
                try Task.checkCancellation()
                self.record = try store.touch(resolved)
                self.saved = true
                let audioURL = try store.playbackAudioURL(for: resolved)
                // prepareToPlay activates the session itself. Configure it before preparing,
                // especially when AudioPlaybackIntent starts the app in the background.
                try self.activateAudioSession()
                let player = try self.makePlayer(audioURL)
                guard player.prepareToPlay() else { throw ReaderError.invalidAudio("音频无法准备播放。") }
                player.enableRate = true
                player.rate = self.rate
                player.numberOfLoops = self.isLooping ? -1 : 0
                player.delegate = self
                self.player = player
                self.duration = player.duration
                try self.play()
                self.installTimer()
            } catch is CancellationError {
                // Closing the sheet explicitly cancels generation; no error is hidden.
            } catch let error as URLError where error.code == .cancelled {
                // URLSession cancellation follows the same explicit close action.
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func startAndWait() async throws {
        start()
        await loadTask?.value
        try Task.checkCancellation()
        if let errorMessage { throw ReaderError.invalidAudio(errorMessage) }
        guard player != nil else { throw ReaderError.invalidAudio("没有可播放的音频。请重试。") }
    }

    func togglePlayback() {
        if isPlaying { pause() }
        else {
            do { try play() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func replay() {
        guard let player else { return }
        player.currentTime = 0
        elapsed = 0
        do { try play() }
        catch { errorMessage = error.localizedDescription }
    }

    func setRate(_ value: Float) {
        guard ReaderConfiguration.rates.contains(value) else { return }
        rate = value
        player?.rate = value
    }

    func setLooping(_ value: Bool) {
        isLooping = value
        player?.numberOfLoops = value ? -1 : 0
    }

    func seek(_ time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), duration)
        elapsed = player.currentTime
    }

    func pause() { player?.pause(); isPlaying = false }

    func close() {
        loadTask?.cancel()
        loadTask = nil
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        if audioSessionActive {
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            catch { NSLog("SonicReader: audio session cleanup failed: %@", error.localizedDescription) }
            audioSessionActive = false
        }
    }

    private func play() throws {
        guard let player else { throw ReaderError.invalidAudio("没有可播放的音频。请重试。") }
        try activateAudioSession()
        if player.currentTime >= player.duration { player.currentTime = 0 }
        guard player.play() else { throw ReaderError.invalidAudio("播放失败。请检查音频输出并重试。") }
        isPlaying = true
        errorMessage = nil
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        audioSessionActive = true
    }

    private func installTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.elapsed = player.currentTime
                self.isPlaying = player.isPlaying
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.elapsed = self.duration
            if !flag { self.errorMessage = "播放未正常完成。请重试。" }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.errorMessage = "音频解码失败，请重新生成。"; self?.pause() }
    }
}
