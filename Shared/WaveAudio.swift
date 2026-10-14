import Foundation

/// /tts/bytes streams WAV with unfinished RIFF/data lengths. Finalize once all bytes arrive.
struct WaveAudio {
    static func finalized(_ input: Data) throws -> Data {
        guard input.count >= 44, Array(input[0..<4]) == Array("RIFF".utf8),
              Array(input[8..<12]) == Array("WAVE".utf8), input.count < Int(UInt32.max) else {
            throw ReaderError.invalidAudio("返回内容不是可播放的 WAV 音频。")
        }
        var data = input
        var offset = 12
        var foundFormat = false
        while offset + 8 <= data.count {
            let tag = String(bytes: data[offset..<offset + 4], encoding: .ascii)
            let length = Int(readUInt32(data, at: offset + 4))
            if tag == "fmt " {
                guard length >= 16, offset + 8 + length <= data.count,
                      readUInt16(data, at: offset + 8) == 1,
                      readUInt16(data, at: offset + 10) == 1,
                      readUInt32(data, at: offset + 12) == 44100,
                      readUInt16(data, at: offset + 22) == 16 else {
                    throw ReaderError.invalidAudio("音频格式与请求的单声道 44.1 kHz PCM 不一致。")
                }
                foundFormat = true
            }
            if tag == "data" {
                let remaining = data.count - offset - 8
                guard foundFormat, remaining > 0, remaining % 2 == 0,
                      length == remaining || length == Int(UInt32.max) else {
                    throw ReaderError.invalidAudio("音频不完整，未保存。请重新生成。")
                }
                writeUInt32(UInt32(remaining), into: &data, at: offset + 4)
                writeUInt32(UInt32(data.count - 8), into: &data, at: 4)
                return data
            }
            guard length <= data.count - offset - 8 else {
                throw ReaderError.invalidAudio("音频文件头不完整。")
            }
            offset += 8 + length + length % 2
        }
        throw ReaderError.invalidAudio("返回的音频没有声音数据。")
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private static func writeUInt32(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}
