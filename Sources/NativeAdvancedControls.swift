import SwiftUI

struct NativeAdvancedControls: View {
    @EnvironmentObject var model: AppModel
    var allowDuration = true
    var body: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Denoise output", isOn: $model.denoiseOutput)
                Text("Cleaner-speech conditioning when reference audio is present.").font(.caption2)
                HStack {
                    Text("Seed")
                    TextField("0", value: $model.generationSeed, formatter: NumberFormatter())
                }
                Text("0 keeps random sampling. A positive seed helps repeat parameter comparisons; it does not select an emotion.").font(.caption2)
                if allowDuration {
                    Toggle("Set target duration", isOn: $model.useDuration)
                    if model.useDuration {
                        HStack {
                            Text("Seconds")
                            TextField("10", value: $model.targetDuration, format: .number)
                        }
                    }
                    Text("Duration overrides Speed-based length estimation for each passage or variant. Silence trimming can make the result shorter; this is not a pause control.").font(.caption2)
                } else {
                    Text("Fixed duration is available for single passages and Variants. Long Form retains per-segment estimation.").font(.caption2)
                }
                SliderRow(title:"Time shift", value:$model.timeShift, range:0.001...1, display:String(format:"%.3f", model.timeShift))
                    .help("t_shift: changes the iterative decoding schedule. Default 0.1.")
                Text("Changes the decoding schedule, not speech timing.").font(.caption2)
                SliderRow(title:"Position temperature", value:$model.positionTemperature, range:0...20, display:String(format:"%.1f", model.positionTemperature))
                    .help("position_temperature: randomness in selecting positions to unmask. Default 5.")
                Text("Randomness in which audio-token positions are filled next.").font(.caption2)
                SliderRow(title:"Token temperature", value:$model.classTemperature, range:0...20, display:String(format:"%.1f", model.classTemperature))
                    .help("class_temperature: randomness in token choices. Zero uses greedy selection.")
                Text("Randomness in token choices; 0 chooses the highest-scoring token.").font(.caption2)
                SliderRow(title:"Codebook layer penalty", value:$model.layerPenaltyFactor, range:0...20, display:String(format:"%.1f", model.layerPenaltyFactor))
                    .help("layer_penalty_factor: preference for filling earlier codebook layers first. Default 5.")
                Text("Encourages earlier audio codebook layers to be filled first.").font(.caption2)
                Button("Reset generation defaults") { model.resetGenerationDefaults() }
                Text("Restores Speed 1, Steps 32, Guidance 2, Denoise on, Seed 0, automatic duration and native decoding defaults.").font(.caption2)
            }.font(.caption).padding(.top, 8)
        }
    }
}
