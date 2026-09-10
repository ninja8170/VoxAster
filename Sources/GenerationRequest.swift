import Foundation

/// Shared wire contract. Engine adapters decide which controls they support.
struct GenerationRequest: Codable, Equatable {
    var text: String
    var refText: String = ""
    var pronunciations: String = ""
    var language: String = "Auto detect"
    var instruct: String = ""
    var speed: Double = 1
    var steps: Int = 32
    var guidance: Double = 2
    var seed: Int = 0
    var denoise: Bool = true
    var duration: Double? = nil
    var timeShift: Double = 0.1
    var positionTemperature: Double = 5
    var classTemperature: Double = 0
    var layerPenaltyFactor: Double = 5
    var pronunciationMode: String = "words"
    var count: Int = 2
    var segments: [String]? = nil
    var retryIndex: Int? = nil

    enum RequestError: LocalizedError {
        case invalid
        var errorDescription: String? { "Check speech text, production segments and generation settings." }
    }

    func fields() throws -> [String: String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              speed.isFinite, (0.5...1.5).contains(speed), (8...64).contains(steps),
              guidance.isFinite, (0...4).contains(guidance), seed >= 0, seed <= Int.max - 4,
              (2...4).contains(count) else { throw RequestError.invalid }
        guard timeShift.isFinite, (0.001...1).contains(timeShift),
              positionTemperature.isFinite, (0...20).contains(positionTemperature),
              classTemperature.isFinite, (0...20).contains(classTemperature),
              layerPenaltyFactor.isFinite, (0...20).contains(layerPenaltyFactor),
              ["words", "substring"].contains(pronunciationMode) else { throw RequestError.invalid }
        if let duration {
            guard duration.isFinite, duration > 0, duration <= 600 else { throw RequestError.invalid }
        }
        var result = ["text": text, "ref_text": refText, "pronunciations": pronunciations,
                      "language": language, "instruct": instruct, "speed": String(speed),
                      "steps": String(steps), "guidance": String(guidance), "seed": String(seed),
                      "denoise": denoise ? "true" : "false", "count": String(count),
                      "t_shift": String(timeShift), "position_temperature": String(positionTemperature),
                      "class_temperature": String(classTemperature), "layer_penalty_factor": String(layerPenaltyFactor),
                      "pronunciation_mode": pronunciationMode]
        if let duration { result["duration"] = String(duration) }
        if let segments {
            guard !segments.isEmpty, segments.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw RequestError.invalid }
            result["segments"] = String(data: try JSONEncoder().encode(segments), encoding: .utf8)
        }
        if let retryIndex {
            guard let segments, segments.indices.contains(retryIndex) else { throw RequestError.invalid }
            result["retry_index"] = String(retryIndex)
        }
        return result
    }
}
