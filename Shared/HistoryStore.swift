import Foundation
import CryptoKit
import AVFAudio
import Darwin

struct ListeningRecord: Codable, Identifiable, Equatable {
    let id: String
    let text: String
    let modelID: String
    let voiceID: String
    let createdAt: Date
    var lastPlayedAt: Date
    let duration: TimeInterval
    let audioBytes: Int
    var isFavorite = false

    private enum CodingKeys: String, CodingKey {
        case id, text, modelID, voiceID, createdAt, lastPlayedAt, duration, audioBytes, isFavorite
    }
}

extension ListeningRecord {
    // Records written before 0.1.5 have no favorite field; migrate that field only.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        modelID = try values.decode(String.self, forKey: .modelID)
        voiceID = try values.decode(String.self, forKey: .voiceID)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        lastPlayedAt = try values.decode(Date.self, forKey: .lastPlayedAt)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        audioBytes = try values.decode(Int.self, forKey: .audioBytes)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}

/// Per-record directories, atomic writes and a cross-process lock avoid losing extension writes.
struct HistoryStore {
    static let maximumRecords = 500
    let root: URL
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var resourceURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }

    static func recordID(text: String) -> String {
        let bytes = Data("\(ReaderConfiguration.modelID)\u{0}\(ReaderConfiguration.voiceID)\u{0}\(text)".utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func list() throws -> [ListeningRecord] {
        try locked {
            try readAll().sorted {
                if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                if $0.lastPlayedAt != $1.lastPlayedAt { return $0.lastPlayedAt > $1.lastPlayedAt }
                return $0.id < $1.id
            }
        }
    }

    func cached(text: String) throws -> ListeningRecord? {
        try locked {
            let directory = root.appendingPathComponent(Self.recordID(text: text), isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
            return try readRecord(directory: directory)
        }
    }

    func save(text: String, audio: Data) throws -> ListeningRecord {
        try locked {
            let id = Self.recordID(text: text)
            let destination = root.appendingPathComponent(id, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                return try readRecord(directory: destination)
            }
            let victims = try evictionCandidates()
            let decoder = try AVAudioPlayer(data: audio)
            guard decoder.duration.isFinite, decoder.duration > 0, decoder.duration < 3600 else {
                throw ReaderError.invalidAudio("音频时长异常，未保存。")
            }
            let now = Date()
            let record = ListeningRecord(id: id, text: text, modelID: ReaderConfiguration.modelID,
                                         voiceID: ReaderConfiguration.voiceID, createdAt: now, lastPlayedAt: now,
                                         duration: decoder.duration, audioBytes: audio.count)
            let temporary = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            do {
                try audio.write(to: temporary.appendingPathComponent("audio.wav"), options: [.atomic, .completeFileProtection])
                try JSONEncoder().encode(record).write(to: temporary.appendingPathComponent("record.json"), options: [.atomic, .completeFileProtection])
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                do { try FileManager.default.removeItem(at: temporary) }
                catch { NSLog("SonicReader: staging cleanup failed: %@", error.localizedDescription) }
                throw error
            }
            // Only remove old records after the new audio and metadata are safely committed.
            for victim in victims {
                try FileManager.default.removeItem(at: root.appendingPathComponent(victim.id, isDirectory: true))
            }
            return record
        }
    }

    /// Preflight avoids paying for new audio when favorites occupy every slot.
    /// save() checks again under the same cross-process lock to cover competing writers.
    func ensureCanSave(text: String) throws {
        try locked {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.recordID(text: text)).path) { return }
            _ = try evictionCandidates()
        }
    }

    func setFavorite(_ record: ListeningRecord, to value: Bool) throws {
        try locked {
            let directory = root.appendingPathComponent(record.id, isDirectory: true)
            var current = try readRecord(directory: directory)
            current.isFavorite = value
            try JSONEncoder().encode(current).write(to: directory.appendingPathComponent("record.json"), options: [.atomic, .completeFileProtection])
        }
    }

    private func readAll() throws -> [ListeningRecord] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .map { try readRecord(directory: $0) }
    }

    private func evictionCandidates() throws -> [ListeningRecord] {
        let records = try readAll()
        let needed = max(0, records.count - Self.maximumRecords + 1)
        guard needed > 0 else { return [] }
        let candidates = records.filter { !$0.isFavorite }.sorted {
            if $0.lastPlayedAt != $1.lastPlayedAt { return $0.lastPlayedAt < $1.lastPlayedAt }
            return $0.id < $1.id
        }
        guard candidates.count >= needed else {
            throw ReaderError.configuration("已达到 500 条存储上限，收藏内容已占满。请删除一条或取消收藏后再生成。")
        }
        return Array(candidates.prefix(needed))
    }

    func touch(_ record: ListeningRecord) throws -> ListeningRecord {
        try locked {
            let directory = root.appendingPathComponent(record.id, isDirectory: true)
            var current = try readRecord(directory: directory)
            current.lastPlayedAt = Date()
            try JSONEncoder().encode(current).write(to: directory.appendingPathComponent("record.json"), options: [.atomic, .completeFileProtection])
            return current
        }
    }

    func delete(_ record: ListeningRecord) throws {
        try locked { try FileManager.default.removeItem(at: root.appendingPathComponent(record.id, isDirectory: true)) }
    }

    func playbackAudioURL(for record: ListeningRecord) throws -> URL {
        try locked {
            _ = try readRecord(directory: root.appendingPathComponent(record.id))
            let destination = root.appendingPathComponent(record.id).appendingPathComponent(SpeechAudioEnhancer.fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                let decoder = try AVAudioPlayer(contentsOf: destination)
                guard abs(decoder.duration - record.duration) < 0.02 else {
                    throw ReaderError.invalidAudio("增强音频时长异常。")
                }
                return destination
            }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".gain-\(UUID().uuidString).wav")
            do {
                try SpeechAudioEnhancer.render(source: audioURL(for: record), destination: temporary)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                if FileManager.default.fileExists(atPath: temporary.path) {
                    do { try FileManager.default.removeItem(at: temporary) }
                    catch { NSLog("SonicReader: gain cleanup failed: %@", error.localizedDescription) }
                }
                throw error
            }
            return destination
        }
    }

    func audioURL(for record: ListeningRecord) -> URL {
        root.appendingPathComponent(record.id, isDirectory: true).appendingPathComponent("audio.wav")
    }

    private func readRecord(directory: URL) throws -> ListeningRecord {
        let record = try JSONDecoder().decode(ListeningRecord.self, from: Data(contentsOf: directory.appendingPathComponent("record.json")))
        guard record.id == directory.lastPathComponent,
              record.id == Self.recordID(text: record.text) else {
            throw ReaderError.configuration("历史记录校验失败，未读取该记录。")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL(for: record).path)
        guard (attributes[.size] as? NSNumber)?.intValue == record.audioBytes else {
            throw ReaderError.invalidAudio("历史音频缺失或不完整。请删除该记录后重新生成。")
        }
        return record
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
}
