import SwiftUI
import UIKit

/// App-level preferences, and About as one section inside them.
///
/// The third tab used to be an About screen wearing a Settings title. It is
/// real now, and it owns app-level concerns — defaults, downloadable assets,
/// notices. The Library keeps owning user *content*, so nothing here deletes a
/// song or a take.
///
/// Sections appear when the phase that needs them lands. Downloads, storage,
/// privacy, and diagnostics are deliberately absent until there is something
/// true to put in them.
struct SettingsView: View {
    let player: StemPlayer
    @ObservedObject var separationModel: SeparationModel
    @AppStorage(LyricsLookup.onlineLookupDefaultsKey)
    private var isOnlineLyricsLookupEnabled = false

    var body: some View {
        NavigationStack {
            Form {
                recordingDefaults
                separationDefaults
                lyrics
                about
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Recording

    /// These are defaults for the *next* take, not part of any song's mix,
    /// which is why they left the Mix card. During a take the transport shows
    /// the values it captured with.
    private var recordingDefaults: some View {
        Section {
            RecordingLevelRow(
                title: "Microphone",
                systemImage: "mic.fill",
                color: .red,
                value: Binding(
                    get: { player.recordingMicrophoneLevel },
                    set: { player.recordingMicrophoneLevel = $0 }
                ),
                range: 0...2,
                accessibilityLabel: "Default microphone recording level"
            )
            RecordingLevelRow(
                title: "Backing",
                systemImage: "waveform",
                color: .indigo,
                value: Binding(
                    get: { player.recordingBackingLevel },
                    set: { player.recordingBackingLevel = $0 }
                ),
                range: 0...1,
                accessibilityLabel: "Default backing recording level"
            )
        } header: {
            Text("Recording defaults")
        } footer: {
            Text("Applied to new takes. The balance of a take you have already recorded can be changed in the Library.")
        }
    }

    // MARK: - Separation

    private var separationDefaults: some View {
        Section {
            Picker(
                "Default separation",
                selection: $separationModel.selectedModel
            ) {
                ForEach(SeparationModelKind.allCases) { kind in
                    Text(kind.outcomeTitle)
                        .tag(kind)
                        .disabled(!kind.isAvailableOnCurrentDevice)
                }
            }
            .pickerStyle(.menu)
            LabeledContent("Stems", value: separationModel.selectedModel.stemSummary)
            LabeledContent("Speed", value: separationModel.selectedModel.speedClass)
        } header: {
            Text("Separation")
        } footer: {
            Text("The choice Studio offers first. You can still pick a different one for any individual song.")
        }
    }

    // MARK: - Lyrics

    /// The only preference in the app that decides whether anything leaves the
    /// device, so it is stated in full and starts off.
    private var lyrics: some View {
        Section {
            Toggle("Look up lyrics online", isOn: $isOnlineLyricsLookupEnabled)
        } header: {
            Text("Lyrics")
        } footer: {
            Text("Off by default. When on, searching for lyrics sends the song title, and the artist if you enter one, to lrclib.net — nothing else, and nothing at all while this is off. Pasting lyrics, importing an .lrc file, and timing lines by tapping all work with no network.")
        }
    }

    // MARK: - About

    private var about: some View {
        Section("About") {
            VStack(spacing: 12) {
                appIcon
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                    .accessibilityHidden(true)
                Text("Atarang")
                    .font(.title2.bold())
                Text("Separate songs into stems, customize the mix, and record yourself playing along.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            LabeledContent("Version", value: appVersion)
            LabeledContent("Author", value: "Shantanu Goel")

            Link(destination: Self.repositoryURL) {
                Label("View Project on GitHub", systemImage: "arrow.up.right.square")
            }
            NavigationLink {
                LicensesView()
            } label: {
                Label("Third-Party Notices", systemImage: "doc.text")
            }
        }
    }

    private static let repositoryURL = URL(string: "https://github.com/shantanugoel/atarang")!

    @ViewBuilder
    private var appIcon: some View {
        if let image = AppIconLoader.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                Color.indigo
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0.0"
    }
}

/// The bundled notices, which were previously in the repository and reachable
/// from nowhere in the app at all. The file ships as a resource so there is one
/// copy of the text rather than a Swift transcription that can drift from it.
struct LicensesView: View {
    var body: some View {
        ScrollView {
            Text(Self.text)
                .font(.footnote)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Third-Party Notices")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let text: AttributedString = {
        guard let url = Bundle.main.url(
            forResource: "THIRD_PARTY_LICENSES",
            withExtension: "md"
        ), let file = try? String(contentsOf: url, encoding: .utf8) else {
            return AttributedString(
                "The third-party notices could not be loaded from this build. They are published with the project source."
            )
        }
        // Inline-only parsing leaves an ATX heading as a literal "# …", and the
        // navigation bar already says what this screen is.
        let markdown = file
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            try? AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        ) ?? AttributedString(markdown)
    }()
}

struct RecordingLevelRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let systemImage: String
    let color: Color
    @Binding var value: Float
    let range: ClosedRange<Float>
    let accessibilityLabel: String

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    labelAndValue
                    slider
                }
            } else {
                HStack(spacing: 12) {
                    Label(title, systemImage: systemImage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(color)
                        .frame(minWidth: 96, alignment: .leading)
                    slider
                    Text(StudioFormat.percent(value))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }

    private var labelAndValue: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(color)
            Spacer()
            Text(StudioFormat.percent(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var slider: some View {
        Slider(value: $value, in: range, step: 0.05)
            .tint(color)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(StudioFormat.percent(value))
    }
}

enum AppIconLoader {
    static var image: UIImage? {
        let bundle = Bundle.main
        let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primaryIcon = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconFiles = primaryIcon?["CFBundleIconFiles"] as? [String]

        guard let iconName = iconFiles?.last else {
            return UIImage(named: "AppIcon")
        }
        return UIImage(named: iconName)
    }
}
