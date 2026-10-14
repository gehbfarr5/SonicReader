import Foundation
import AVFAudio
import AudioToolbox

/// Apple AUPeakLimiter applies gain before limiting. Originals remain untouched for rollback.
struct SpeechAudioEnhancer {
    static let fileName = "audio-speech-gain-v2.wav"
    static let preGainDB: Float = 6
    static let outputHeadroomDB: Float = -2

    static func render(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.channelCount == 1, format.sampleRate == 44100, input.length > 0 else {
            throw ReaderError.invalidAudio("音量增强收到不支持的音频格式。")
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(player)
        engine.attach(limiter)
        engine.connect(player, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        for (parameter, value) in [(kLimiterParam_PreGain, preGainDB), (kLimiterParam_AttackTime, Float(0.001)), (kLimiterParam_DecayTime, Float(0.04))] {
            let status = AudioUnitSetParameter(limiter.audioUnit, parameter, kAudioUnitScope_Global, 0, value, 0)
            guard status == noErr else { throw ReaderError.configuration("音量增强配置失败（\(status)）。") }
        }
        engine.mainMixerNode.outputVolume = pow(10, outputHeadroomDB / 20)
        let maximumFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrames)
        guard let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maximumFrames),
              let trimmed = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maximumFrames) else {
            throw ReaderError.invalidAudio("无法创建音量增强缓冲区。")
        }
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        player.scheduleFile(input, at: nil)
        try engine.start()
        defer { player.stop(); engine.stop(); engine.disableManualRenderingMode() }
        player.play()
        let latency = limiter.auAudioUnit.latency
        guard latency.isFinite, latency >= 0, latency < 0.5 else { throw ReaderError.invalidAudio("音量增强延迟异常。") }
        let latencyFrames = AVAudioFramePosition((latency * format.sampleRate).rounded())
        let finalFrame = input.length + latencyFrames
        var retries = 0
        var written: AVAudioFramePosition = 0
        while engine.manualRenderingSampleTime < finalFrame {
            try Task.checkCancellation()
            let start = engine.manualRenderingSampleTime
            let count = AVAudioFrameCount(min(AVAudioFramePosition(maximumFrames), finalFrame - start))
            let status = try engine.renderOffline(count, to: rendered)
            switch status {
            case .success:
                retries = 0
                let skip = Int(max(0, min(AVAudioFramePosition(rendered.frameLength), latencyFrames - start)))
                let kept = min(Int(rendered.frameLength) - skip, Int(input.length - written))
                guard kept >= 0, let original = rendered.floatChannelData?[0], let target = trimmed.floatChannelData?[0] else {
                    throw ReaderError.invalidAudio("音量增强输出不完整。")
                }
                if kept > 0 {
                    for i in 0..<kept {
                        let sample = original[skip + i]
                        guard sample.isFinite, abs(sample) < 1 else { throw ReaderError.invalidAudio("音量增强输出超过安全峰值，未保存。") }
                        target[i] = sample
                    }
                    trimmed.frameLength = AVAudioFrameCount(kept)
                    try output.write(from: trimmed)
                    written += AVAudioFramePosition(kept)
                }
            case .cannotDoInCurrentContext:
                retries += 1
                guard retries <= 20 else { throw ReaderError.invalidAudio("音量增强无法完成。") }
            case .insufficientDataFromInputNode, .error:
                throw ReaderError.invalidAudio("音量增强未收到完整音频。")
            @unknown default:
                throw ReaderError.invalidAudio("音量增强返回未知状态。")
            }
        }
        guard written == input.length else { throw ReaderError.invalidAudio("音量增强时长不匹配，未保存。") }
    }
}
