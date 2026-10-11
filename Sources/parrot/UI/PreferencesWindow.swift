import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhisperKit

/// Hosts `PreferencesView` in a plain `NSWindow`. A singleton so the menu bar
/// item never opens two copies.
@MainActor
enum PreferencesWindowController {
    private static var window: NSWindow?

    /// - Parameters:
    ///   - transcriber: the daemon's already-warmed-up transcriber, reused
    ///     for file transcription so it doesn't load the model a second time.
    ///   - activeModelID: id of the model that's actually loaded right now —
    ///     not necessarily whatever's selected in the model picker below,
    ///     since that only takes effect after "Salva e riavvia".
    static func show(transcriber: WhisperKitTranscriber, activeModelID: String) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: PreferencesView(transcriber: transcriber, activeModelID: activeModelID)
        )
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Preferenze parrot"
        newWindow.styleMask = [.titled, .closable]
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PreferencesView: View {
    let transcriber: WhisperKitTranscriber
    let activeModelID: String

    @State private var selectedModelID: String
    @State private var selectedHotkey: Hotkey
    @State private var autostart = LaunchAgent.isInstalled
    @State private var checks: [Check]
    @State private var downloadingModelID: String?
    @State private var downloadProgress: Double = 0
    @State private var statusMessage: String?

    @State private var pickedAudioURL: URL?
    @State private var isTranscribingFile = false
    @State private var fileTranscript: String?
    @State private var fileTranscribeElapsed: TimeInterval?
    @State private var fileTranscribeError: String?

    init(transcriber: WhisperKitTranscriber, activeModelID: String) {
        self.transcriber = transcriber
        self.activeModelID = activeModelID
        let config = ParrotConfig.load()
        let hotkey = Hotkey.parse(config.hotkey)
        _selectedModelID = State(initialValue: config.model ?? ModelRegistry.recommended()?.id ?? "")
        _selectedHotkey = State(initialValue: hotkey)
        _checks = State(initialValue: DoctorReport.run(hotkey: hotkey))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            modelSection
            Divider()
            hotkeySection
            Divider()
            autostartSection
            Divider()
            doctorSection
            Divider()
            transcribeFileSection
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Modello").font(.headline)
            ForEach(ModelRegistry.shared, id: \.id) { model in
                HStack {
                    Button {
                        selectedModelID = model.id
                    } label: {
                        HStack {
                            Image(systemName: selectedModelID == model.id ? "largecircle.fill.circle" : "circle")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                Text("\(model.sizeMB) MB · \(model.languages.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if downloadingModelID == model.id {
                        ProgressView(value: downloadProgress)
                            .frame(width: 80)
                    } else if model.isDownloaded {
                        Label("Scaricato", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                    } else {
                        Button("Scarica") { download(model) }
                            .disabled(downloadingModelID != nil)
                    }
                }
            }
        }
    }

    private func download(_ model: TranscriptionModel) {
        guard let whisperKitID = model.whisperKitID else { return }
        downloadingModelID = model.id
        downloadProgress = 0
        statusMessage = nil
        Task {
            do {
                _ = try await WhisperKit.download(variant: whisperKitID) { progress in
                    Task { @MainActor in
                        downloadProgress = progress.fractionCompleted
                    }
                }
                await MainActor.run {
                    downloadingModelID = nil
                    statusMessage = "\(model.displayName) scaricato."
                }
            } catch {
                await MainActor.run {
                    downloadingModelID = nil
                    statusMessage = "Download di \(model.displayName) fallito: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Hotkey

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hotkey").font(.headline)
            Picker("", selection: $selectedHotkey) {
                Text("Fn").tag(Hotkey.fn)
                Text("Shift destro").tag(Hotkey.rightShift)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Tenendolo premuto registra finché non lo rilasci. Premendolo due volte di seguito parte la registrazione senza doverlo tenere premuto — un'altra pressione la ferma.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Autostart

    private var autostartSection: some View {
        Toggle("Avvia automaticamente al login", isOn: Binding(
            get: { autostart },
            set: { newValue in
                do {
                    try LaunchAgent.setEnabled(newValue)
                    autostart = newValue
                } catch {
                    statusMessage = "Errore: \(error.localizedDescription)"
                }
            }
        ))
    }

    // MARK: - Doctor

    private var doctorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Diagnostica").font(.headline)
                Spacer()
                Button("Aggiorna") {
                    checks = DoctorReport.run(hotkey: selectedHotkey)
                }
            }
            ForEach(checks, id: \.name) { check in
                HStack {
                    icon(for: check.status)
                    Text(check.name)
                    Spacer()
                    if case .fail = check.status, check.name == "accessibility" {
                        Button("Apri Impostazioni") { openAccessibilitySettings() }
                            .font(.caption)
                    }
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func icon(for status: CheckStatus) -> some View {
        switch status {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .fail:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Transcribe file

    private var transcribeFileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trascrivi un file audio").font(.headline)
            Text("Usa il modello già in memoria (\(activeModelID)), offline.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Scegli file audio…") { pickAudioFile() }
                    .disabled(isTranscribingFile)
                if let pickedAudioURL {
                    Text(pickedAudioURL.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isTranscribingFile {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Trascrivi") { transcribeFile() }
                        .disabled(pickedAudioURL == nil)
                }
            }

            if let fileTranscribeError {
                Text(fileTranscribeError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let fileTranscript {
                ScrollView {
                    Text(fileTranscript.isEmpty ? "(nessun parlato rilevato)" : fileTranscript)
                        .font(.callout)
                        .foregroundStyle(fileTranscript.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))

                HStack {
                    if let fileTranscribeElapsed {
                        Text(String(format: "%.1fs", fileTranscribeElapsed))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Salva come TXT…") { saveTranscriptAsTXT(fileTranscript) }
                        .disabled(fileTranscript.isEmpty)
                    Button("Esporta come PDF…") { saveTranscriptAsPDF(fileTranscript) }
                        .disabled(fileTranscript.isEmpty)
                }
            }
        }
    }

    private func pickAudioFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Scegli un file audio da trascrivere"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedAudioURL = url
        fileTranscript = nil
        fileTranscribeError = nil
        fileTranscribeElapsed = nil
    }

    private func transcribeFile() {
        guard let pickedAudioURL else { return }
        isTranscribingFile = true
        fileTranscribeError = nil
        fileTranscript = nil
        Task {
            let started = Date()
            do {
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: pickedAudioURL.path)
                let text = try await transcriber.transcribe(samples)
                await MainActor.run {
                    fileTranscript = text
                    fileTranscribeElapsed = Date().timeIntervalSince(started)
                    isTranscribingFile = false
                }
            } catch {
                await MainActor.run {
                    fileTranscribeError = "Trascrizione fallita: \(error.localizedDescription)"
                    isTranscribingFile = false
                }
            }
        }
    }

    private func saveTranscriptAsTXT(_ text: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = transcriptBaseName() + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Trascrizione salvata in \(url.lastPathComponent)."
        } catch {
            fileTranscribeError = "Salvataggio fallito: \(error.localizedDescription)"
        }
    }

    private func saveTranscriptAsPDF(_ text: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = transcriptBaseName() + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PDFTextExporter.write(text: text, title: pickedAudioURL?.lastPathComponent ?? "Trascrizione", to: url)
            statusMessage = "PDF salvato in \(url.lastPathComponent)."
        } catch {
            fileTranscribeError = "Esportazione PDF fallita: \(error.localizedDescription)"
        }
    }

    private func transcriptBaseName() -> String {
        pickedAudioURL?.deletingPathExtension().lastPathComponent ?? "trascrizione"
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Salva e riavvia") { saveAndRestart() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(ModelRegistry.find(selectedModelID)?.isDownloaded ?? false))
            }
        }
    }

    private func saveAndRestart() {
        do {
            try ParrotConfig.save(model: selectedModelID, hotkey: selectedHotkey.rawValue)
            LaunchAgent.restart()
            statusMessage = "Salvato — il demone si sta riavviando."
        } catch {
            statusMessage = "Errore nel salvataggio: \(error.localizedDescription)"
        }
    }
}
