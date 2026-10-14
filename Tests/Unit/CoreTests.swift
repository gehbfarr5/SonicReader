import XCTest
import AVFAudio
@testable import SonicReader

final class CoreTests: XCTestCase {
    func testInputRejectsMissingURLAndLongText() throws {
        XCTAssertThrowsError(try SelectionText.validate(" \n "))
        XCTAssertThrowsError(try SelectionText.validate("https://example.com"))
        XCTAssertThrowsError(try SelectionText.validate(String(repeating: "a", count: 4001)))
        XCTAssertEqual(try SelectionText.validate("  It's a good day.\n"), "It's a good day.")
    }

    func testStreamingWaveFinalizationAndMalformedAudio() throws {
        let streaming = Self.wave(seconds: 0.5, streaming: true)
        let final = try WaveAudio.finalized(streaming)
        XCTAssertNotEqual(final.prefix(8), streaming.prefix(8))
        XCTAssertEqual(try AVAudioPlayer(data: final).duration, 0.5, accuracy: 0.01)
        XCTAssertEqual(try WaveAudio.finalized(final), final)
        XCTAssertThrowsError(try WaveAudio.finalized(Data("{\"error\":\"unauthorized\"}".utf8)))
        XCTAssertThrowsError(try WaveAudio.finalized(streaming.dropLast()))
    }

    func testHistorySurvivesReopenDeduplicatesAndDetectsMissingAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root)
        let text = "A reusable sentence."
        let audio = try WaveAudio.finalized(Self.wave(seconds: 0.3))
        let first = try store.save(text: text, audio: audio)
        let repeated = try store.save(text: text, audio: audio)
        XCTAssertEqual(first.id, repeated.id)
        let reopened = try HistoryStore(root: root)
        XCTAssertEqual(try reopened.list().count, 1)
        XCTAssertEqual(try reopened.cached(text: text)?.text, text)
        let second = try store.save(text: "Another sentence.", audio: audio)
        _ = try store.touch(first)
        XCTAssertEqual(try reopened.list().first?.id, first.id)
        try reopened.delete(second)
        XCTAssertEqual(try reopened.list().count, 1)
        try FileManager.default.removeItem(at: store.audioURL(for: first))
        XCTAssertThrowsError(try reopened.cached(text: text))
    }

    @MainActor
    func testCachedPlaybackRatesLoopAndCloseWithoutAPIKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root)
        _ = try store.save(text: "Cached.", audio: WaveAudio.finalized(Self.wave(seconds: 0.4)))
        let model = PlayerModel(text: "Cached.", store: store)
        model.start()
        for _ in 0..<30 {
            if !model.isLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isPlaying)
        for rate in ReaderConfiguration.rates { model.setRate(rate); XCTAssertEqual(model.rate, rate) }
        model.setRate(1)
        model.setLooping(true)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(model.isPlaying, "Loop must outlast more than two durations")
        model.pause(); XCTAssertFalse(model.isPlaying)
        model.replay(); XCTAssertTrue(model.isPlaying)
        model.close(); XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(try store.list().count, 1)
    }

    func testAudioEnhancementPreservesOriginalAndCachesWithoutAccumulatingGain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root)
        let audio = try WaveAudio.finalized(Self.wave(seconds: 0.5))
        let record = try store.save(text: "Quiet audio.", audio: audio)
        let original = store.audioURL(for: record)
        let enhanced = try store.playbackAudioURL(for: record)
        XCTAssertNotEqual(original, enhanced)
        XCTAssertEqual(try Data(contentsOf: original), audio)
        XCTAssertEqual(try AVAudioPlayer(contentsOf: enhanced).duration, record.duration, accuracy: 0.001)
        let first = try Data(contentsOf: enhanced)
        XCTAssertNotEqual(first, audio)
        XCTAssertEqual(try store.playbackAudioURL(for: record), enhanced)
        XCTAssertEqual(try Data(contentsOf: enhanced), first, "Repeated playback must not increase gain again")
        let originalLevels = try Self.levels(original)
        let enhancedLevels = try Self.levels(enhanced)
        XCTAssertGreaterThan(enhancedLevels.rms, originalLevels.rms * 1.3, "Quiet recordings must be audibly boosted")
        XCTAssertEqual(try store.list().count, 1)
        try store.delete(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: enhanced.path))
        let loud = try store.save(text: "Loud peaks.", audio: WaveAudio.finalized(Self.wave(seconds: 0.5, amplitude: 30000)))
        let limited = try store.playbackAudioURL(for: loud)
        XCTAssertLessThan(try Self.levels(limited).peak, 0.9, "Limiter must leave headroom instead of clipping loud peaks")
    }

    func testHTTPErrorIsExplicitAndNoAlternateModelIsCalled() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RejectingProtocol.self]
        let session = URLSession(configuration: config)
        do {
            _ = try await CartesiaClient(session: session).synthesize(text: "Hello.", key: "test-key")
            XCTFail("Expected HTTP 401")
        } catch ReaderError.http(let status) { XCTAssertEqual(status, 401) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testShortcutSessionOwnsPlaybackAndRejectsStaleControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root)
        _ = try store.save(text: "Copied sentence.", audio: WaveAudio.finalized(Self.wave(seconds: 0.4)))
        let player = PlayerModel(text: "Copied sentence.", store: store)
        let session = ShortcutReadingSession()
        let id = try session.begin(text: player.text, player: player)
        XCTAssertFalse(player.isPlaying, "Creating a session must not start audio before confirmation")
        XCTAssertThrowsError(try session.begin(text: "Overlapping."))
        XCTAssertThrowsError(try session.require("stale"))
        try await session.require(id).startAndWait()
        XCTAssertTrue(player.isPlaying)
        player.setLooping(true)
        player.setRate(0.8)
        session.end("stale")
        XCTAssertTrue(player.isPlaying)
        session.end(id)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(session.model)
        XCTAssertThrowsError(try session.require(id))
    }

    @MainActor
    func testColdSessionConfiguredBeforeConstructingPlayerAndAfterClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root)
        let audio = try WaveAudio.finalized(Self.wave(seconds: 0.5))
        let record = try store.save(text: "Cold start sentence.", audio: audio)
        let session = AVAudioSession.sharedInstance()
        for _ in 0..<2 {
            try session.setActive(false)
            try session.setCategory(.ambient, mode: .default)
            var constructions = 0
            let model = PlayerModel(text: record.text, store: store, makePlayer: { url in
                constructions += 1
                // With the old ordering these assertions fail: configuration happened
                // only in play(), after the constructor and prepareToPlay().
                XCTAssertEqual(session.category, .playback)
                XCTAssertEqual(session.mode, .spokenAudio)
                return try AVAudioPlayer(contentsOf: url)
            })
            defer { model.close() }
            try await model.startAndWait()
            XCTAssertEqual(constructions, 1)
            XCTAssertTrue(model.isPlaying)
            model.replay()
            XCTAssertTrue(model.isPlaying)
            model.close()
            XCTAssertFalse(model.isPlaying)
        }
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: record)), audio)
        XCTAssertEqual(try store.list().count, 1, "Cold activation must not regenerate or remove cached recordings")
    }

    @MainActor
    func testSystemRepeatActionReusesAudioAndCancellationStopsSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root)
        let original = try store.save(text: "Repeat this sentence.", audio: WaveAudio.finalized(Self.wave(seconds: 0.5)))
        let player = PlayerModel(text: original.text, store: store)
        let session = ShortcutReadingSession()
        let id = try session.begin(text: original.text, player: player)
        try await player.startAndWait()
        var presentations = Set<String>()
        var calls = 0
        do {
            defer { session.end(id) }
            try await session.repeatUntilClosed(id) { presentationID in
                calls += 1
                XCTAssertTrue(presentations.insert(presentationID).inserted, "Each replay must request a distinct presentation")
                XCTAssertTrue(player.isPlaying)
                if calls > 1 { XCTAssertEqual(player.elapsed, 0, accuracy: 0.02, "Positive action must rewind existing audio") }
                XCTAssertEqual(player.record?.id, original.id)
                if calls == 4 { throw CancellationError() }
                player.seek(0.2)
            }
            XCTFail("Closing must leave the confirmation loop")
        } catch is CancellationError { }
        XCTAssertEqual(calls, 4, "Three accepted replays and one close")
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(session.id)
        XCTAssertThrowsError(try session.require(id))
        XCTAssertEqual(try store.list().count, 1, "Repeated playback must not synthesize or save another recording")
    }

    @available(iOS 26.0, *)
    @MainActor
    func testClipboardIntentRejectsEmptyBeforeConfirmation() async {
        var intent = ReadCopiedTextIntent()
        intent.text = "  \n "
        do { _ = try await intent.perform(); XCTFail("Empty clipboard must fail before any system UI or API request") }
        catch { XCTAssertTrue(error.localizedDescription.contains("剪贴板没有文字")) }
        XCTAssertNil(ShortcutReadingSession.shared.id)
    }

    func testLegacyFavoritesPersistAcrossPlaybackAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root)
        let old = try store.save(text: "Legacy sentence.", audio: WaveAudio.finalized(Self.wave(seconds: 0.02)))
        let path = root.appendingPathComponent(old.id).appendingPathComponent("record.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        json.removeValue(forKey: "isFavorite")
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        XCTAssertFalse(try XCTUnwrap(store.cached(text: old.text)).isFavorite)
        let recent = try store.save(text: "Recent sentence.", audio: WaveAudio.finalized(Self.wave(seconds: 0.02)))
        try store.setFavorite(old, to: true)
        _ = try store.touch(recent)
        XCTAssertEqual(try store.list().first?.id, old.id, "Favorites must sort above newer ordinary records")
        _ = try store.touch(old) // The stale caller's favorite=false must not replace saved metadata.
        let reopened = try HistoryStore(root: root)
        XCTAssertTrue(try XCTUnwrap(reopened.cached(text: old.text)).isFavorite)
        try reopened.setFavorite(old, to: false)
        XCTAssertFalse(try XCTUnwrap(store.cached(text: old.text)).isFavorite)
        json["isFavorite"] = "invalid"
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        XCTAssertThrowsError(try store.list(), "Corrupt metadata must not silently migrate as false")
    }

    func testCapacityEvictsOldestOrdinaryAudioOnlyAfterSuccessfulSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root)
        let records = try Self.seedCapacity(store: store)
        try store.setFavorite(records[0], to: true)
        XCTAssertThrowsError(try store.save(text: "Invalid audio.", audio: Data()))
        XCTAssertEqual(try store.list().count, 500, "Failed generation must preserve all old recordings")
        let replacement = try store.save(text: "New sentence.", audio: WaveAudio.finalized(Self.wave(seconds: 0.02)))
        XCTAssertEqual(try store.list().count, 500)
        XCTAssertNotNil(try store.cached(text: records[0].text), "Oldest favorite must survive")
        XCTAssertNil(try store.cached(text: records[1].text), "Oldest ordinary recording must be evicted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: records[1]).path))
        XCTAssertNotNil(try store.cached(text: replacement.text))
    }

    @MainActor
    func testAllFavoriteCapacityBlocksGenerationButAllowsCachedPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root)
        let records = try Self.seedCapacity(store: store, favorite: true)
        XCTAssertThrowsError(try store.ensureCanSave(text: "Brand new."))
        XCTAssertNoThrow(try store.ensureCanSave(text: records[0].text))
        let model = PlayerModel(text: "Brand new.", store: store)
        model.start()
        do { try await model.startAndWait(); XCTFail("Full favorites must prevent generation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("收藏内容已占满"), "Capacity must be checked before even requesting a Keychain key") }
        XCTAssertEqual(try store.list().count, 500)
        try store.setFavorite(records[0], to: false)
        XCTAssertNoThrow(try store.ensureCanSave(text: "Brand new."))
        _ = try store.save(text: "Brand new.", audio: WaveAudio.finalized(Self.wave(seconds: 0.02)))
        XCTAssertEqual(try store.list().count, 500)
        XCTAssertNil(try store.cached(text: records[0].text))
    }

    func testConcurrentWritersMaintainCapacityAndProtectFavorites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root)
        let records = try Self.seedCapacity(store: store)
        try store.setFavorite(records[0], to: true)
        let audio = try WaveAudio.finalized(Self.wave(seconds: 0.02))
        async let first = Task.detached { try store.save(text: "Concurrent A.", audio: audio) }.value
        async let second = Task.detached { try store.save(text: "Concurrent B.", audio: audio) }.value
        _ = try await (first, second)
        XCTAssertEqual(try store.list().count, 500)
        XCTAssertNotNil(try store.cached(text: records[0].text))
        XCTAssertNotNil(try store.cached(text: "Concurrent A."))
        XCTAssertNotNil(try store.cached(text: "Concurrent B."))
    }

    private static func seedCapacity(store: HistoryStore, favorite: Bool = false) throws -> [ListeningRecord] {
        // Fixture 500 valid recordings directly, avoiding 500 unrelated API calls.
        let audio = try WaveAudio.finalized(wave(seconds: 0.02))
        return try (0..<500).map { index in
            let text = "Capacity fixture \(index)."
            let record = ListeningRecord(id: HistoryStore.recordID(text: text), text: text,
                modelID: ReaderConfiguration.modelID, voiceID: ReaderConfiguration.voiceID,
                createdAt: Date(timeIntervalSince1970: Double(index)), lastPlayedAt: Date(timeIntervalSince1970: Double(index)),
                duration: 0.02, audioBytes: audio.count, isFavorite: favorite)
            let directory = store.root.appendingPathComponent(record.id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try audio.write(to: directory.appendingPathComponent("audio.wav"))
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("record.json"))
            return record
        }
    }

    static func levels(_ url: URL) throws -> (rms: Double, peak: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        var squares = 0.0
        var peak = 0.0
        for index in 0..<Int(buffer.frameLength) {
            let sample = Double(channel[index]); squares += sample * sample; peak = max(peak, abs(sample))
        }
        return (sqrt(squares / Double(buffer.frameLength)), peak)
    }

    static func wave(seconds: Double, streaming: Bool = false, amplitude: Double = 1000) -> Data {
        let count = Int(seconds * 44100)
        var data = Data()
        func u16(_ value: UInt16) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 2)) }
        func u32(_ value: UInt32) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 4)) }
        data.append(Data("RIFF".utf8)); u32(streaming ? UInt32.max : UInt32(36 + count * 2))
        data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(streaming ? UInt32.max : UInt32(count * 2))
        for i in 0..<count { u16(UInt16(bitPattern: Int16(sin(Double(i) * 2 * .pi * 440 / 44100) * amplitude))) }
        return data
    }
}

private final class RejectingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"error\":\"invalid api key\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
