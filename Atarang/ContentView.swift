import SwiftUI

struct ContentView: View {
    @StateObject private var model = SeparationModel()
    @StateObject private var player = StemPlayer()
    @State private var youtubeURL = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    hero
                    if player.isLoaded { mixer } else { importCard }
                    if model.isWorking { progressCard }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Atarang")
            .alert("Couldn’t separate this song", isPresented: errorIsPresented) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "Unknown error")
            }
        }
        .tint(.indigo)
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.indigo)
            Text("Your song, your part")
                .font(.title2.bold())
            Text("Separate a track, turn down any instrument, and play along.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Separate a song", systemImage: "link")
                .font(.headline)
            TextField("Paste a YouTube URL", text: $youtubeURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
            Button {
                Task {
                    if let track = await model.separate(youtubeURL: youtubeURL) {
                        do { try player.load(track: track) }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                }
            } label: {
                Label("Create four stems", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
        }
        .cardStyle()
    }

    private var progressCard: some View {
        VStack(spacing: 12) {
            ProgressView(value: model.progress)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusText).font(.subheadline.weight(.medium))
                    Text("Keep Atarang open while it works")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(model.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var mixer: some View {
        VStack(spacing: 18) {
            VStack(spacing: 5) {
                Text(player.title).font(.headline).lineLimit(2)
                Text("4-stem mix").font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 5) {
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 0.01))
                HStack {
                    Text(time(player.position))
                    Spacer()
                    Text("−\(time(max(0, player.duration - player.position)))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 62, height: 62)
                    .background(.indigo, in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            VStack(spacing: 14) {
                ForEach(StemKind.allCases) { stem in
                    StemRow(stem: stem, volume: Binding(
                        get: { player.volume(for: stem) },
                        set: { player.setVolume($0, for: stem) }
                    ))
                }
            }

            Button("Choose another song", systemImage: "arrow.triangle.2.circlepath") {
                player.unload()
                youtubeURL = ""
            }
            .font(.subheadline)
        }
        .cardStyle()
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private func time(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct StemRow: View {
    let stem: StemKind
    @Binding var volume: Float

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: stem.icon)
                .frame(width: 25)
                .foregroundStyle(stem.color)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(stem.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(volume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $volume, in: 0...1)
                    .tint(stem.color)
            }
            Button {
                volume = volume == 0 ? 1 : 0
            } label: {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(volume == 0 ? .secondary : stem.color)
            .accessibilityLabel(volume == 0 ? "Unmute \(stem.title)" : "Mute \(stem.title)")
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview { ContentView() }
