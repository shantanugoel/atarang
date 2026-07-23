import SwiftUI

struct RecordingMixEditor: View {
    @ObservedObject var store: HistoryStore
    let recording: HistoryRecording

    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = RecordingMixPreviewPlayer()
    @State private var microphoneLevel: Float
    @State private var backingLevel: Float
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(store: HistoryStore, recording: HistoryRecording) {
        self.store = store
        self.recording = recording
        _microphoneLevel = State(initialValue: recording.microphoneLevel)
        _backingLevel = State(initialValue: recording.backingLevel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        Button {
                            preview.togglePlayback()
                        } label: {
                            Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .frame(width: 58, height: 58)
                                .background(.indigo, in: Circle())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                        .accessibilityLabel(preview.isPlaying ? "Pause preview" : "Play preview")

                        Slider(
                            value: Binding(
                                get: { preview.position },
                                set: { preview.seek(to: $0) }
                            ),
                            in: 0...max(preview.duration, 0.01)
                        )
                        .disabled(isSaving)
                        .accessibilityLabel("Preview position")

                        HStack {
                            Text(time(preview.position))
                            Spacer()
                            Text("−\(time(max(0, preview.duration - preview.position)))")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                } header: {
                    Text(recording.title)
                }

                Section {
                    MixLevelControl(
                        title: "Mic",
                        systemImage: "mic.fill",
                        color: .red,
                        value: $microphoneLevel,
                        range: 0...2
                    )
                    MixLevelControl(
                        title: "Backing",
                        systemImage: "waveform",
                        color: .indigo,
                        value: $backingLevel,
                        range: 0...1
                    )
                } header: {
                    HStack {
                        Text("Mix")
                        Spacer()
                        Button("Reset") {
                            microphoneLevel = recording.microphoneLevel
                            backingLevel = recording.backingLevel
                        }
                        .textCase(nil)
                        .disabled(!hasChanges || isSaving)
                    }
                } footer: {
                    Text("Preview changes live. Your original microphone and backing recordings stay untouched.")
                }

                Section {
                    Button {
                        save(asNew: false)
                    } label: {
                        saveLabel("Save Mix", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || isSaving)

                    Button {
                        save(asNew: true)
                    } label: {
                        saveLabel("Save as New Mix", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
            .navigationTitle("Edit Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear {
                do {
                    try preview.load(recording: recording)
                    preview.setLevels(
                        microphone: microphoneLevel,
                        backing: backingLevel
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .onChange(of: microphoneLevel) { _, newValue in
                preview.setLevels(microphone: newValue, backing: backingLevel)
            }
            .onChange(of: backingLevel) { _, newValue in
                preview.setLevels(microphone: microphoneLevel, backing: newValue)
            }
            .onDisappear { preview.stop(releaseSession: true) }
            .alert("Couldn’t edit mix", isPresented: errorIsPresented) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? preview.errorMessage ?? "Unknown error")
            }
        }
    }

    private var hasChanges: Bool {
        abs(microphoneLevel - recording.microphoneLevel) >= 0.001
            || abs(backingLevel - recording.backingLevel) >= 0.001
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil || preview.errorMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                    preview.errorMessage = nil
                }
            }
        )
    }

    private func save(asNew: Bool) {
        preview.pause()
        isSaving = true
        Task {
            do {
                try await store.saveMix(
                    recording: recording,
                    microphoneLevel: microphoneLevel,
                    backingLevel: backingLevel,
                    asNew: asNew
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func saveLabel(_ title: String, systemImage: String) -> some View {
        HStack {
            if isSaving {
                ProgressView()
            } else {
                Image(systemName: systemImage)
            }
            Text(isSaving ? "Saving…" : title)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func time(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct MixLevelControl: View {
    let title: String
    let systemImage: String
    let color: Color
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(color)
                Spacer()
                Text("\(percentage)%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: 0.05)
                .tint(color)
                .accessibilityLabel("\(title) level")
                .accessibilityValue("\(percentage) percent")
        }
        .padding(.vertical, 4)
    }

    private var percentage: Int {
        Int((value * 100).rounded())
    }
}
