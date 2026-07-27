import SwiftUI
import UIKit

/// The screen that decides what a song will become.
///
/// It used to lead with a menu of architecture names — HTDemucs, MDX23C — and
/// leave the consequences to a caption. It leads with the outcome now: what you
/// end up with, how long it takes, whether it runs on this device, and whether
/// it needs a download. The architecture is still shown, one line down, for
/// anyone who wants it.
struct ImportView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var youtubeURL: String
    @Binding var selectedModel: SeparationModelKind
    let isBusy: Bool
    /// Only to badge the outcomes this song already has. Acting on them is
    /// `ImportActionBar`'s job.
    let existingModels: [SeparationModelKind]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            urlSection
            outcomeSection
        }
        .padding(18)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    // MARK: - URL

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Separate a song", systemImage: "link")
                .font(.headline)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        urlField
                        pasteButton.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    HStack(spacing: 8) {
                        urlField
                        pasteButton
                    }
                }
            }
            if let urlValidationMessage {
                Label(urlValidationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if trimmedURL.isEmpty {
                Text("Paste a YouTube video link to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Drawn rather than using `.roundedBorder`, because the clear button has
    /// to live inside the border: overlaid on a system-styled field it sits on
    /// top of the text, and a long YouTube URL runs straight under it.
    private var urlField: some View {
        HStack(spacing: 4) {
            TextField("Paste a YouTube URL", text: $youtubeURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.plain)
                .accessibilityLabel("YouTube URL")
            if !trimmedURL.isEmpty {
                Button {
                    youtubeURL = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        // Narrow enough not to crowd the field, tall enough to
                        // hit without looking.
                        .frame(width: 30, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the link")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(minHeight: 44)
        .background(
            Color(.tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1)
        )
    }

    private var pasteButton: some View {
        Button("Paste") {
            if let value = UIPasteboard.general.string { youtubeURL = value }
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .accessibilityHint("Pastes a YouTube link from the clipboard")
    }

    private var trimmedURL: String {
        youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var urlValidationMessage: String? {
        guard !trimmedURL.isEmpty else { return nil }
        return YouTubeSource.validatedURL(from: trimmedURL) == nil
            ? "Enter a valid youtube.com or youtu.be video link."
            : nil
    }

    // MARK: - Outcome

    private var outcomeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What do you want out of it?")
                .font(.subheadline.weight(.semibold))
            ForEach(SeparationModelKind.allCases) { kind in
                OutcomeCard(
                    kind: kind,
                    isSelected: selectedModel == kind,
                    isRecommended: kind == SeparationModelKind.recommendedForCurrentDevice,
                    alreadySeparated: existingModels.contains(kind)
                ) {
                    selectedModel = kind
                }
                .disabled(isBusy)
            }
        }
    }

}

/// The one thing to do on this screen, pinned so it is never the thing below
/// the fold.
///
/// It used to be the last item in a scrolling card, under four outcome cards
/// that are taller than a phone: someone who pasted a link saw the choices and
/// no way to act on them, with nothing on screen saying there was more. It sits
/// in the safe area now, the same place the transport does once a song is open,
/// so the screen always shows what pressing on looks like.
struct ImportActionBar: View {
    @Binding var selectedModel: SeparationModelKind
    let youtubeURL: String
    let isBusy: Bool
    let existingSeparation: LocalTrack?
    let existingModels: [SeparationModelKind]
    let separate: () -> Void
    let separateAgain: () -> Void
    let openExisting: (LocalTrack) -> Void

    private var isURLValid: Bool {
        YouTubeSource.validatedURL(from: youtubeURL) != nil
    }

    var body: some View {
        VStack(spacing: 12) {
            if let existingSeparation {
                Button {
                    openExisting(existingSeparation)
                } label: {
                    Label("Open Saved \(selectedModel.outcomeTitle)", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text(
                    "Separated \(existingSeparation.createdAt.formatted(.relative(presentation: .named))). Opening it costs nothing."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Kept visually apart from the primary action on purpose: this
                // one spends minutes of battery to reproduce something the
                // device already has.
                Divider().padding(.vertical, 2)
                Button("Separate Again", role: .destructive, action: separateAgain)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .disabled(isBusy)
                    .accessibilityHint("Discards the saved stems and runs the separation again")
            } else {
                Button(action: separate) {
                    Label(
                        "Create \(selectedModel.outcomeTitle)",
                        systemImage: "wand.and.stars"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    !isURLValid || isBusy || !selectedModel.isAvailableOnCurrentDevice
                )
                if !existingModels.isEmpty {
                    Text(
                        "This song is already saved as \(existingModels.map(\.outcomeTitle).joined(separator: ", ")). Select one of those to open it instantly."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// One separation outcome, with everything needed to choose it visible before
/// the choice is made.
private struct OutcomeCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let kind: SeparationModelKind
    let isSelected: Bool
    let isRecommended: Bool
    let alreadySeparated: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(kind.outcomeTitle)
                        .font(.subheadline.weight(.semibold))
                    if isRecommended { badge("Recommended", color: .indigo) }
                    if alreadySeparated { badge("Saved", color: .green) }
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.indigo : .secondary)
                }
                Text(kind.outcomeDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                facts
                if let message = kind.unavailabilityMessage {
                    Label(unavailabilityCopy(message), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                isSelected ? Color.indigo.opacity(0.1) : Color(.tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isSelected ? Color.indigo.opacity(0.5) : .clear,
                        lineWidth: 1
                    )
            )
            .opacity(kind.isAvailableOnCurrentDevice ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var facts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { factLabels }
            VStack(alignment: .leading, spacing: 4) { factLabels }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var factLabels: some View {
        Label(kind.stemSummary, systemImage: "square.stack.3d.up")
            .lineLimit(1)
        Label(kind.speedClass, systemImage: "clock")
        Label(installedText, systemImage: installedIcon)
    }

    private var installedText: String {
        if kind.downloadSize == nil { return "Built in" }
        if ModelAssetStore.isInstalled(kind) { return "Downloaded" }
        return "Downloads \(kind.downloadSize ?? "once") once"
    }

    private var installedIcon: String {
        if kind.downloadSize == nil { return "shippingbox" }
        return ModelAssetStore.isInstalled(kind) ? "checkmark.icloud" : "arrow.down.circle"
    }

    private func unavailabilityCopy(_ message: String) -> String {
        guard let alternative = kind.suggestedAlternative else { return message }
        return "\(message) Choose \(alternative.outcomeTitle) instead."
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}
