import SwiftUI
import AppKit

// MARK: - Engine Lab (separate window)

struct EngineLabWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = NSRange(location: 0, length: 0)

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Picker("A", selection: $model.engineLabEngineA) {
                        ForEach(model.engineLabAvailableEngines, id: \.self) { Text($0).tag($0) }
                    }
                    Text("vs").font(.traceValue).foregroundStyle(Trace.graphite)
                    Picker("B", selection: $model.engineLabEngineB) {
                        ForEach(model.engineLabAvailableEngines, id: \.self) { Text($0).tag($0) }
                    }
                }
                .labelsHidden()
                if model.engineLabEngineA == model.engineLabEngineB {
                    Text("Choose two different engines.").font(.traceCaption).foregroundStyle(Trace.record)
                }

                VStack(spacing: 0) {
                    if model.engineLabSupportsNative {
                        EventBar(text: $model.engineLabText, selection: $selection, performance: false)
                        Hairline()
                    }
                    CursorTextEditor(text: $model.engineLabText, selection: $selection, font: Trace.scriptNSFont,
                                     lineSpacing: 6, inset: NSSize(width: 16, height: 14))
                }
                .traceSheet()
                .frame(minHeight: 160)
                if !model.engineLabSupportsNative {
                    Text("F5-TTS takes plain text: clear pronunciation rules, set language to Auto, and leave advanced settings at their defaults.")
                        .font(.traceCaption).foregroundStyle(Trace.graphite)
                }

                if let a = model.engineLabA, let b = model.engineLabB {
                    VStack(alignment: .leading, spacing: 10) {
                        BlindLane(label: "A", url: a)
                        BlindLane(label: "B", url: b)
                        HStack {
                            Text("Which is better?").font(.traceSection)
                            Picker("Choice", selection: Binding(get: { model.engineLabWinner ?? "" }, set: { model.engineLabWinner = $0 })) {
                                Text("A").tag("A"); Text("B").tag("B")
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 100)
                            Spacer()
                            Button("Reveal Engines") { model.revealEngineComparison() }
                                .disabled(model.engineLabWinner == nil || model.engineLabRevealed)
                        }
                        if model.engineLabRevealed, let winner = model.engineLabWinner {
                            Text("You chose \(winner): \(model.engineLabMap[winner] ?? "unknown").")
                                .font(.traceBody).foregroundStyle(Trace.ink)
                        }
                    }
                    .padding(14)
                    .traceSheet()
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(minWidth: 460)

            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Shared reference")
                if let ref = model.referenceURL {
                    Text(ref.deletingPathExtension().lastPathComponent).font(.traceBody)
                    PlayerTrace(url: ref, controller: model.referencePlayer, stacked: true).frame(height: 90)
                } else {
                    Text("No reference selected").font(.traceBody).foregroundStyle(Trace.graphite)
                }
                Menu("Choose Reference") {
                    ForEach(model.savedVoices) { voice in Button(voice.name) { model.selectEngineLabVoice(voice) } }
                    Divider()
                    Button("Choose Audio File…") { model.chooseReference() }
                }
                .fixedSize()
                Hairline()
                ValueSlider(label: "Speed (shared)", value: $model.speed, range: 0.5...1.5, format: "%.2f")
                if model.engineLabSupportsNative {
                    DisclosureGroup("OmniVoice settings") { AdvancedRender(allowDuration: true).padding(.top, 8) }
                        .font(.traceSection)
                }
                Spacer()
                Text(model.engineLabStatus).font(.traceCaption).foregroundStyle(Trace.graphite)
                Button {
                    model.runEngineComparison()
                } label: {
                    Text(model.engineLabRunning ? "Comparing…" : "Generate A / B").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Trace.cobalt).controlSize(.large)
                .disabled(model.engineLabRunning || model.referenceURL == nil
                          || model.engineLabEngineA == model.engineLabEngineB || model.engineLabAvailableEngines.count < 2)
            }
            .padding(18)
            .frame(minWidth: 260, idealWidth: 290, maxWidth: 340)
            .background(Trace.ground)
        }
        .background(Trace.ground)
        .navigationTitle("Engine Lab")
        .navigationSubtitle("Blind comparison")
        .onAppear { model.checkEngineLab() }
    }
}

struct BlindLane: View {
    @EnvironmentObject var model: AppModel
    let label: String
    let url: URL
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 15, weight: .semibold, design: .monospaced)).frame(width: 18)
            PlayerTrace(url: url, controller: model.outputPlayer, showRuler: false).frame(height: 34)
            if model.engineLabRevealed {
                Text(model.engineLabMap[label] ?? "").font(.traceCaption).foregroundStyle(Trace.graphite).frame(width: 130, alignment: .trailing)
            }
        }
    }
}

// MARK: - Settings scene (⌘,)

enum DependencyCredits {
    static let boson = "Built with Higgs Materials licensed from Boson AI USA, Inc., Copyright Boson AI USA, Inc., All Rights Reserved and Meta Llama 3 licensed under the Meta Llama 3 Community License, Copyright Meta Platforms, Inc., All Right Reserved"
    static let meta = "Built with Meta Llama 3; based on Meta Llama 3."
}

struct PreferencesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            Form {
                Toggle("Play generated audio automatically", isOn: $model.autoPlay)
                Toggle("Keep WAV files when deleting takes", isOn: $model.keepOutputs)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Status") {
                    LabeledContent("OmniVoice model", value: model.modelReady ? "Ready" : (model.runtimeSelection == nil ? "Setup required" : "Loading"))
                    LabeledContent("Device", value: "Apple Silicon · MPS")
                    LabeledContent("F5-TTS", value: model.f5Available ? "Available" : "Not installed")
                    LabeledContent("Local server", value: "127.0.0.1:8011")
                }
                Section("Runtime") {
                    Text("Setup and repair only touch the managed runtime. Voices, projects and drafts are kept.")
                        .font(.traceCaption).foregroundStyle(.secondary)
                    Button("Set Up or Repair Runtime…") {
                        model.runtimeSetup.repair = model.runtimeSelection?.managed != nil
                        model.runtimeSetup.presented = true
                    }
                }
                if !model.runtimeProvenance.isEmpty {
                    Section("Provenance") {
                        ForEach(model.runtimeProvenance.keys.sorted(), id: \.self) { key in
                            LabeledContent(key.replacingOccurrences(of: "_", with: " ")) {
                                Text(model.runtimeProvenance[key] ?? "").font(.traceValue).textSelection(.enabled).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Engine", systemImage: "cpu") }

            Form {
                storageRow("Generated audio", "Documents/OmniVoice-Mac/outputs")
                storageRow("Reference voices", "Documents/OmniVoice-Mac/voices")
                storageRow("Trained engines", "Documents/OmniVoice-Mac/personal-voice/engines")
                storageRow("Productions", "Documents/OmniVoice-Mac/performance")
            }
            .formStyle(.grouped)
            .tabItem { Label("Storage", systemImage: "internaldrive") }

            Form {
                Section {
                    Text("VoxAster \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
                    Text("VoxAster code: MIT. OmniVoice code: Apache-2.0. OmniVoice weights: separate non-commercial terms.")
                    Text(DependencyCredits.boson)
                    Text(DependencyCredits.meta)
                    Text("The unmodified audio tokenizer uses the Boson Higgs Audio 2 Community License, including Meta's licence and acceptable-use terms. Training is not included.")
                }
                .font(.traceCaption)
                .textSelection(.enabled)
                Button("Open Bundled Licences") {
                    if let resources = Bundle.main.resourceURL { NSWorkspace.shared.open(resources.appendingPathComponent("Licenses")) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Credits", systemImage: "doc.text") }
        }
        .frame(width: 560, height: 440)
    }

    private func storageRow(_ label: String, _ relative: String) -> some View {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative)
        return LabeledContent(label) {
            HStack {
                Text("~/" + relative).font(.traceValue).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Show") { NSWorkspace.shared.open(url) }.controlSize(.small)
            }
        }
    }
}
