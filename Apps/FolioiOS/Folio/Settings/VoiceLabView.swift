import SwiftUI
import FolioCore
import FolioAudio
import FolioNeural

/// Natural voices in one place: the models on this iPhone, one tap to make
/// a voice yours for every language it speaks, the user's own voice server,
/// and the Voice Lab.
struct NaturalVoicesView: View {
    @Environment(ListenModel.self) private var listen

    var body: some View {
        List {
            Section {
                modelRow(.supertonic, title: "Supertonic-3",
                         detail: "One voice for Czech, Slovak, German, English and Spanish · highlights the sentence")
                if listen.installedModels.contains(.supertonic) {
                    voicePicker(.supertonic)
                }
                modelRow(.kokoro, title: "Kokoro", detail: "English and Spanish · highlights word by word")
                if listen.kokoroCrashed {
                    Text("Kokoro stopped the app while it was speaking on this iPhone, so Folio switched it off and went back to automatic voices for English and Spanish. Tap Download to try it again.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if listen.installedModels.contains(.kokoro) {
                    voicePicker(.kokoro)
                }
                modelRow(.paradee, title: "Paradee Lite",
                         detail: "English, American and British · 11 MB, runs on the processor · highlights the sentence")
                if listen.installedModels.contains(.paradee) {
                    voicePicker(.paradee)
                }
            } header: {
                Text("On this iPhone")
            } footer: {
                Text("Downloaded once, then they work offline. Tap ▶ to hear a voice and Use to make it yours; you can still choose another voice per language in Voices. "
                     + (listen.isTestBuild ? "In this test build they work without Premium." : "Listening with them is part of Premium; previews are free."))
            }

            Section {
                NavigationLink {
                    VoiceServerView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your voice server")
                        Text(serverSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("voice-server")
            } footer: {
                Text("Like BookOrbit: connect your own Kokoro server (Kokoro-FastAPI) or any OpenAI-compatible speech server, and its voices appear here. Text goes only to your server.")
            }

            Section {
                NavigationLink {
                    VoiceLabView()
                } label: {
                    Label("Voice Lab: blind test and speed check", systemImage: "flask")
                }
                .accessibilityIdentifier("voice-lab")
            }
        }
        .navigationTitle("Natural voices")
        .onDisappear { listen.stopPreview() }
    }

    private var serverSummary: String {
        switch listen.voiceServerStatus {
        case .notSet: "Not connected"
        case .connecting: "Connecting…"
        case .connected(let count): "\(count) voices · \(listen.preferences.voiceServerURL ?? "")"
        case .failed(let message): message
        }
    }

    @ViewBuilder
    private func modelRow(_ model: NeuralVoiceCatalog.Model, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if listen.installedModels.contains(model) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityLabel("Downloaded")
            } else if listen.modelDownloads[model] == .downloading {
                ProgressView().accessibilityLabel("Downloading")
            } else {
                Button("Download") { listen.downloadModel(model) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("download-\(model.rawValue)")
            }
        }
        if case .failed(let message) = listen.modelDownloads[model] {
            Text("Download failed: \(message)").font(.footnote).foregroundStyle(.orange)
        }
    }

    /// One row per voice of the model: ▶ preview, name, where it's in use, Use.
    @ViewBuilder
    private func voicePicker(_ model: NeuralVoiceCatalog.Model) -> some View {
        ForEach(distinctVoices(model), id: \.modelVoice) { voice in
            let inUse = listen.languages(using: voice.modelVoice, model: model)
            let sample = listen.voices.first { $0.id == voice.id } ?? SpeechVoice(id: voice.id, name: voice.name, language: voice.language,
                                                                                 quality: .neural, engineID: NeuralVoiceCatalog.engineID)
            HStack(spacing: 12) {
                Button {
                    listen.preview(sample, text: VoiceLabSamples.paragraph(for: LanguageCode(voice.language).base))
                } label: {
                    Image(systemName: listen.previewingVoiceID == voice.id ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2).foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Preview \(voice.name)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name).font(.body.weight(inUse.isEmpty ? .regular : .semibold))
                    Text(inUse.isEmpty ? languageList(model, voice) : "In use for " + inUse.map(VoiceText.language).joined(separator: ", "))
                        .font(.caption).foregroundStyle(inUse.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
                Spacer(minLength: 0)
                let complete = !inUse.isEmpty && inUse.count == languageCount(model, voice)
                Button(complete ? "Using" : (inUse.isEmpty ? "Use" : "Use for all")) { listen.useNeuralVoice(voice.modelVoice, model: model) }
                    .buttonStyle(.bordered)
                    .disabled(complete)
                    .accessibilityIdentifier("use-\(voice.modelVoice)")
            }
        }
        if let error = listen.previewError { Text(error).font(.footnote).foregroundStyle(.orange) }
    }

    /// Each model voice once (a Supertonic voice is listed per language in the catalog).
    private func distinctVoices(_ model: NeuralVoiceCatalog.Model) -> [NeuralVoiceCatalog.Voice] {
        var seen: Set<String> = []
        return NeuralVoiceCatalog.all.filter { $0.model == model && seen.insert($0.modelVoice).inserted }
    }

    private func languageCount(_ model: NeuralVoiceCatalog.Model, _ voice: NeuralVoiceCatalog.Voice) -> Int {
        NeuralVoiceCatalog.all.filter { $0.model == model && $0.modelVoice == voice.modelVoice }.count
    }

    private func languageList(_ model: NeuralVoiceCatalog.Model, _ voice: NeuralVoiceCatalog.Voice) -> String {
        NeuralVoiceCatalog.all.filter { $0.model == model && $0.modelVoice == voice.modelVoice }
            .map { VoiceText.language(LanguageCode($0.language).base) }
            .joined(separator: ", ")
    }
}

/// Connect the user's own speech server.
struct VoiceServerView: View {
    @Environment(ListenModel.self) private var listen
    @State private var address = ""
    @State private var apiKey = ""
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.0.19:8880", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("voice-server-address")
                SecureField("API key (if your server needs one)", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(listen.voiceServerStatus == .connecting ? "Connecting…" : "Connect") {
                    Task { await listen.connectVoiceServer(address: address, apiKey: apiKey) }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || listen.voiceServerStatus == .connecting)
            } header: {
                Text("Server")
            } footer: {
                Text("The address of Kokoro-FastAPI or another OpenAI-compatible speech server, with or without /v1 (BookOrbit's format works). On a home network or Tailscale, http is fine. The key is kept in the Keychain.")
            }

            switch listen.voiceServerStatus {
            case .connected(let count):
                Section {
                    Label("\(count) voices available. Choose one in Voices for each language.", systemImage: "checkmark.circle")
                    Button("Disconnect", role: .destructive) { confirmRemove = true }
                }
            case .failed(let message):
                Section { Text(message).foregroundStyle(.orange) }
            case .notSet, .connecting:
                EmptyView()
            }

            Section {
                Text("Word-by-word highlighting works with Kokoro-FastAPI. Other servers read fine and highlight the paragraph. Folio caches what it heard on this iPhone, so a paragraph is fetched once, and nothing is sent anywhere else.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Your voice server")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if address.isEmpty { address = listen.preferences.voiceServerURL ?? "" } }
        .confirmationDialog("Disconnect your voice server? Voices from it go back to automatic.", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await listen.removeVoiceServer() } }
        }
    }
}

/// Tools for deciding whether a neural voice is good enough to ship: a blind
/// A/B against the best Apple voice, a speed and memory check on this iPhone,
/// and the storage the models take.
struct VoiceLabView: View {
    @Environment(ListenModel.self) private var listen
    @State private var language = "en"
    @State private var neuralID: String?
    @State private var neuralIsA = Bool.random()
    @State private var results = VoiceLabResults.load()
    @State private var benchmarkVoiceID: String?
    @State private var running = false
    @State private var report: String?
    @State private var benchmarkError: String?
    @State private var bytes: Int64?
    @State private var confirmRemove = false

    private let languages = ["en", "es", "de", "cs", "sk"]

    private var neuralVoices: [SpeechVoice] {
        listen.voices.filter { NeuralVoiceCatalog.isNeural($0.id) && $0.isInstalled && $0.languageCode.base == language }
    }
    private var installedNeural: [SpeechVoice] { listen.voices.filter { NeuralVoiceCatalog.isNeural($0.id) && $0.isInstalled } }
    private var appleVoice: SpeechVoice? {
        VoiceLibrary.automaticVoice(for: language, region: Locale.current.region?.identifier, in: listen.voices)
    }
    private var neuralVoice: SpeechVoice? { neuralVoices.first { $0.id == neuralID } ?? neuralVoices.first }

    var body: some View {
        Form {
            Section {
                Text("A neural voice ships to everyone only if it beats Apple's best voice in a blind test and runs reliably on real iPhones. These tools collect that evidence on your device.")
                    .font(.subheadline)
            }

            Section {
                Picker("Language", selection: $language) {
                    ForEach(languages, id: \.self) { Text(VoiceText.language($0)).tag($0) }
                }
                if neuralVoices.isEmpty {
                    Text("Download a neural voice for \(VoiceText.language(language)) in the Voice Library first.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let neural = neuralVoice, let apple = appleVoice {
                    Picker("Neural voice", selection: Binding(get: { neural.id }, set: { neuralID = $0 })) {
                        ForEach(neuralVoices) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        playButton("A", voice: neuralIsA ? neural : apple)
                        Spacer()
                        playButton("B", voice: neuralIsA ? apple : neural)
                    }
                    HStack {
                        voteButton("A is better") { record(neuralWins: neuralIsA) }
                        Spacer()
                        voteButton("Same") { record(neuralWins: nil) }
                        Spacer()
                        voteButton("B is better") { record(neuralWins: !neuralIsA) }
                    }
                } else {
                    Text("No Apple voice is installed for \(VoiceText.language(language)) to compare with.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                let tally = results[language] ?? VoiceLabResults.Tally()
                LabeledContent("Results", value: "Neural \(tally.neural) · Apple \(tally.apple) · Same \(tally.same)")
            } header: {
                Text("Blind test")
            } footer: {
                Text("Both voices read the same passage at your speed. A and B are shuffled after every vote, so you never know which is which. Apple's side is the voice Folio would pick automatically.")
            }

            Section {
                Picker("Voice", selection: Binding(get: { benchmarkVoiceID ?? installedNeural.first?.id ?? "" },
                                                   set: { benchmarkVoiceID = $0 })) {
                    ForEach(installedNeural) { Text("\($0.name) · \(VoiceText.language($0.languageCode.base))").tag($0.id) }
                }
                .disabled(installedNeural.isEmpty)
                Button(running ? "Measuring…" : "Run speed check") { runBenchmark() }
                    .disabled(running || installedNeural.isEmpty)
                if let report {
                    Text(report).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy results") { UIPasteboard.general.string = report }
                }
                if let benchmarkError { Text(benchmarkError).font(.footnote).foregroundStyle(.orange) }
            } header: {
                Text("Speed check")
            } footer: {
                Text("Renders three passages from scratch on this iPhone: model load time, render time against audio length (RTF below 1 keeps up with playback), word timing coverage and memory headroom. Mac numbers say nothing about an iPhone, so these are the ones that count.")
            }

            Section {
                LabeledContent("Neural voices and narration", value: bytes.map(Format.bytes) ?? "…")
                Button("Remove neural voices", role: .destructive) { confirmRemove = true }
                    .disabled(listen.installedModels.isEmpty)
            } header: {
                Text("Storage")
            }
        }
        .navigationTitle("Voice Lab")
        .task { bytes = await listen.neuralBytesOnDisk() }
        .onChange(of: language) {
            neuralID = nil
            neuralIsA = .random()
        }
        .onDisappear { listen.stopPreview() }
        .confirmationDialog("Remove the downloaded neural voices and their rendered narration?", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await listen.removeNeuralVoices()
                    bytes = await listen.neuralBytesOnDisk()
                }
            }
        }
    }

    private func playButton(_ label: String, voice: SpeechVoice) -> some View {
        Button {
            listen.preview(voice, text: VoiceLabSamples.paragraph(for: language))
        } label: {
            Label(listen.previewingVoiceID == voice.id ? "Stop" : "Play \(label)",
                  systemImage: listen.previewingVoiceID == voice.id ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(listen.previewingVoiceID == voice.id ? "Stop" : "Play voice \(label)")
    }

    private func voteButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.borderless).font(.subheadline.weight(.semibold))
    }

    private func record(neuralWins: Bool?) {
        listen.stopPreview()
        var tally = results[language] ?? VoiceLabResults.Tally()
        switch neuralWins {
        case true?: tally.neural += 1
        case false?: tally.apple += 1
        case nil: tally.same += 1
        }
        results[language] = tally
        VoiceLabResults.save(results)
        neuralIsA = .random()
    }

    private func runBenchmark() {
        guard let voiceID = benchmarkVoiceID ?? installedNeural.first?.id else { return }
        running = true
        report = nil
        benchmarkError = nil
        Task {
            do {
                let result = try await listen.benchmark(voiceID: voiceID)
                report = "\(DeviceInfo.summary)\n\(Date().formatted(date: .abbreviated, time: .shortened))\n\(result.report)"
            } catch {
                benchmarkError = "The speed check failed: \(error.localizedDescription)"
            }
            running = false
        }
    }
}

/// Blind-test votes per language, kept on this device.
enum VoiceLabResults {
    struct Tally: Codable, Equatable {
        var neural = 0
        var apple = 0
        var same = 0
    }

    private static let key = "folio.voiceLab.results"

    static func load() -> [String: Tally] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Tally].self, from: data)) ?? [:]
    }

    static func save(_ results: [String: Tally]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(results), forKey: key)
    }
}

/// The same passages for every voice, so comparisons are fair.
enum VoiceLabSamples {
    static func paragraph(for language: String) -> String {
        switch language {
        case "es": "El tren nocturno salió de la estación a la hora exacta. La mayoría de los pasajeros ya dormía, pero algunos se quedaron junto a las ventanas, mirando pasar las luces de los pueblos. Cerca de la frontera, el revisor empezó a tararear una vieja canción."
        case "de": "Der Nachtzug verließ den Bahnhof pünktlich auf die Minute. Die meisten Fahrgäste schliefen schon, doch einige blieben an den Fenstern und sahen die Lichter kleiner Städte vorbeiziehen. Kurz vor der Grenze begann der Schaffner, ein altes Lied zu summen."
        case "cs": "Noční vlak odjel z nádraží přesně na čas. Většina cestujících už spala, ale několik jich zůstalo u oken a dívalo se, jak kolem ubíhají světla malých měst. Někde u hranic začal průvodčí pobrukovat starou píseň."
        case "sk": "Nočný vlak odišiel zo stanice presne načas. Väčšina cestujúcich už spala, no niekoľkí zostali pri oknách a pozerali, ako okolo ubiehajú svetlá malých miest. Niekde pri hraniciach začal sprievodca pospevovať starú pieseň."
        default: "The night train left the station exactly on time. Most passengers were already asleep, but a few stayed by the windows, watching the lights of small towns slide past. Somewhere near the border, the conductor began to hum an old song."
        }
    }

    /// Short, medium and long passages in the voice's language.
    static func paragraphs(for voiceID: String) -> [String] {
        let language = NeuralVoiceCatalog.voice(voiceID).map { LanguageCode($0.language).base } ?? "en"
        let paragraph = paragraph(for: language)
        let firstSentence = paragraph.split(separator: ".").first.map { String($0) + "." } ?? paragraph
        return [firstSentence, paragraph, paragraph + " " + paragraph]
    }
}

enum DeviceInfo {
    static var summary: String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(machine), iOS \(UIDevice.current.systemVersion)"
    }
}
