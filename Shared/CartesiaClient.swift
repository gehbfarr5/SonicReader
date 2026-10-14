import Foundation

struct CartesiaClient {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func synthesize(text: String, key: String) async throws -> Data {
        let text = try SelectionText.validate(text)
        var request = URLRequest(url: URL(string: "https://api.cartesia.ai/tts/bytes")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(ReaderConfiguration.apiVersion, forHTTPHeaderField: "Cartesia-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model_id": ReaderConfiguration.modelID,
            "voice": ReaderConfiguration.voiceID,
            "transcript": text,
            "language": "en",
            "generation_config": ["volume": 1.0],
            "output_format": ["container": "wav", "encoding": "pcm_s16le", "sample_rate": 44100]
        ])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw ReaderError.configuration("没有收到有效的服务器响应。")
        }
        guard response.statusCode == 200 else { throw ReaderError.http(response.statusCode) }
        return try WaveAudio.finalized(data)
    }
}
