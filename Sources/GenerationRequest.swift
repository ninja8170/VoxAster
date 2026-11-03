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

    enum RequestError: LocalizedError, Equatable {
        case invalid
        /// One named problem, so the alert says what to fix rather than "check your settings".
        case problem(String)
        var errorDescription: String? {
            switch self {
            case .invalid: return "Check speech text, production segments and generation settings."
            case .problem(let message): return message
            }
        }
    }

    /// Fails with a message naming the setting and its allowed range.
    private func require(_ ok: Bool, _ message: @autoclosure () -> String) throws {
        if !ok { throw RequestError.problem(message()) }
    }

    private func within(_ value: Double, _ range: ClosedRange<Double>) -> Bool { value.isFinite && range.contains(value) }

    func fields() throws -> [String: String] {
        try require(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write something to speak first.")
        try require(within(speed, 0.5...1.5), "Speed must be between 0.5 and 1.5 (Render › Speed).")
        try require((8...64).contains(steps), "Steps must be between 8 and 64 (Render › Steps).")
        try require(within(guidance, 0...4), "Guidance must be between 0 and 4 (Render › Guidance).")
        try require(seed >= 0 && seed <= Int.max - 4, "Seed must be 0 (random) or a positive whole number (Render › Advanced › Seed).")
        try require((2...4).contains(count), "Takes must be between 2 and 4.")
        try require(within(timeShift, 0.001...1), "Time shift must be between 0.001 and 1 (Render › Advanced).")
        try require(within(positionTemperature, 0...20), "Position temperature must be between 0 and 20 (Render › Advanced).")
        try require(within(classTemperature, 0...20), "Token temperature must be between 0 and 20 (Render › Advanced).")
        try require(within(layerPenaltyFactor, 0...20), "Layer penalty must be between 0 and 20 (Render › Advanced).")
        try require(["words", "substring"].contains(pronunciationMode), "Unknown pronunciation match mode.")
        if let duration {
            try require(duration.isFinite && duration > 0 && duration <= 600,
                        "Fixed duration must be more than 0 and at most 600 seconds (Render › Advanced › Seconds).")
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
            try require(!segments.isEmpty, "There are no segments to render.")
            if let blank = segments.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                throw RequestError.problem("Segment \(blank + 1) is empty. Write its text or press Split Script again.")
            }
            result["segments"] = String(data: try JSONEncoder().encode(segments), encoding: .utf8)
        }
        if let retryIndex {
            guard let segments, segments.indices.contains(retryIndex) else {
                throw RequestError.problem("That segment no longer exists. Press Split Script and try again.")
            }
            result["retry_index"] = String(retryIndex)
        }
        return result
    }
}
