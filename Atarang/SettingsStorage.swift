import SwiftUI

/// The state behind the three Settings screens that talk about the disk.
///
/// They share one object because they share one question — what is on this
/// device — and answering it means walking folders, which should happen once
/// per visit rather than once per row.
@MainActor
@Observable
final class StorageSettingsModel {
    private(set) var breakdown = StorageBreakdown()
    private(set) var availableBytes: Int64 = 0
    private(set) var evictable: [CachedOriginals.Candidate] = []
    private(set) var quarantinedCount = 0
    private(set) var report: LibraryIntegrityReport?
    private(set) var isWorking = false

    /// Reads everything the storage screens show. Cheap enough to run on
    /// appearance: the expensive measurements come from the library index,
    /// which has already cached them.
    ///
    /// Takes the store rather than a snapshot, and waits for a fresh one first.
    /// A caller that has just evicted or repaired something would otherwise
    /// measure the library as it was before its own change.
    func refresh(store: HistoryStore) async {
        isWorking = true
        defer { isWorking = false }
        await store.refreshNow()
        let snapshot = store.snapshot
        let measured = await Task.detached(priority: .utility) {
            (
                breakdown: StorageBreakdown.measure(snapshot: snapshot),
                available: StorageCapacity.availableBytes(),
                quarantined: LibraryIntegrity.quarantinedFolders().count,
                stored: LibraryIntegrity.storedReport()
            )
        }.value
        breakdown = measured.breakdown
        availableBytes = measured.available
        quarantinedCount = measured.quarantined
        evictable = CachedOriginals.candidates(in: snapshot)
        if var stored = measured.stored {
            // The stored report was written at launch, before there was a
            // snapshot to measure. The findings are still current; the totals
            // beside them should not be a launch-time memory.
            stored.breakdown = measured.breakdown
            stored.availableBytes = measured.available
            report = stored
        }
    }

    /// Re-runs the full integrity pass — inspect, repair, quarantine — which is
    /// what a rescan means.
    func rescan(store: HistoryStore) async {
        isWorking = true
        defer { isWorking = false }
        let breakdown = self.breakdown
        let fresh = await Task.detached(priority: .utility) {
            LibraryIntegrity.runPass(breakdown: breakdown)
        }.value
        report = fresh
        NotificationCenter.default.post(name: .atarangLibraryDidChange, object: nil)
        await refresh(store: store)
    }

    var evictableBytes: Int64 {
        evictable.reduce(0) { $0 + $1.byteCount }
    }

    var separatedEvictable: [CachedOriginals.Candidate] {
        evictable.filter(\.hasSeparation)
    }

    func evict(_ candidates: [CachedOriginals.Candidate], store: HistoryStore) async {
        guard !candidates.isEmpty else { return }
        CachedOriginals.evict(candidates)
        NotificationCenter.default.post(name: .atarangLibraryDidChange, object: nil)
        await refresh(store: store)
    }

    func emptyQuarantine(store: HistoryStore) async {
        LibraryIntegrity.emptyQuarantine()
        await refresh(store: store)
    }
}

// MARK: - Downloads & Models

/// Every optional asset the app can download, with what it costs and a way to
/// get rid of it.
///
/// Deleting one here is not deleting content: a model is re-downloadable from
/// the same pinned URL and checksum it came from, which is exactly why it is
/// safe to offer. Songs and takes stay in the Library.
struct ModelsSettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var separationModel: SeparationModel
    @State private var installedBytes: [SeparationModelKind: Int64] = [:]
    @State private var pendingRemoval: SeparationModelKind?
    @State private var errorMessage: String?

    private var optionalModels: [SeparationModelKind] {
        SeparationModelKind.allCases.filter { $0.downloadByteCount != nil }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Balanced 4-stem") {
                    Text("Bundled")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Included")
            } footer: {
                Text("The default separation ships inside the app and cannot be removed.")
            }

            Section {
                ForEach(optionalModels) { model in
                    row(for: model)
                }
            } header: {
                Text("Optional downloads")
            } footer: {
                Text("Each is downloaded once, verified against a pinned checksum, and kept out of iCloud backup. Removing one frees its space; choosing it again downloads it again.")
            }

            if let total = totalInstalledBytes, total > 0 {
                Section {
                    LabeledContent(
                        "Downloaded models",
                        value: StorageCapacity.formatted(total)
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Downloads & Models")
        .navigationBarTitleDisplayMode(.inline)
        .task { measure() }
        .alert(
            "Remove \(pendingRemoval?.outcomeTitle ?? "model")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let pendingRemoval { remove(pendingRemoval) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Separations you have already made are unaffected. Choosing this model again downloads it again (\(pendingRemoval?.downloadSize ?? "")).")
        }
        .alert(
            "Could not remove model",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func row(for model: SeparationModelKind) -> some View {
        let installed = (installedBytes[model] ?? 0) > 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.outcomeTitle)
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                Text(
                    installed
                        ? StorageCapacity.formatted(installedBytes[model] ?? 0)
                        : (model.downloadSize ?? "")
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Text(model.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label(
                    installed ? "Installed" : "Not downloaded",
                    systemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle"
                )
                .font(.caption)
                .foregroundStyle(installed ? Color.green : .secondary)
                if !model.isAvailableOnCurrentDevice {
                    Text("Unavailable on this device")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if installed {
                Button(role: .destructive) {
                    pendingRemoval = model
                } label: {
                    Label("Remove Download", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private var totalInstalledBytes: Int64? {
        let total = installedBytes.values.reduce(0, +)
        return total > 0 ? total : nil
    }

    private func measure() {
        var sizes: [SeparationModelKind: Int64] = [:]
        for model in optionalModels where ModelAssetStore.isInstalled(model) {
            sizes[model] = ModelAssetStore.installedByteCount(model)
        }
        installedBytes = sizes
    }

    private func remove(_ model: SeparationModelKind) {
        Task {
            do {
                try await ModelAssetStore.shared.remove(model)
                // A default that is no longer installed is still a valid
                // choice — it downloads again on use — so the preference is
                // left alone. Only an unusable one is corrected.
                if separationModel.selectedModel == model,
                   !model.isAvailableOnCurrentDevice {
                    separationModel.selectedModel = .recommendedForCurrentDevice
                }
                measure()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Storage

/// What is on the device, by the categories the user thinks in, and the two
/// ways to get some of it back that do not delete anything they made.
struct StorageSettingsView: View {
    @ObservedObject var store: HistoryStore
    @Bindable var model: StorageSettingsModel
    @State private var evictionScope: EvictionScope?

    private enum EvictionScope: Identifiable {
        case separated
        case all

        var id: Int { self == .separated ? 0 : 1 }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Free for use", value: StorageCapacity.formatted(model.availableBytes))
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Atarang refuses a download, separation, take, or export it cannot finish, and says how much more room it needs.")
            }

            Section("On this device") {
                total("Originals", "arrow.down.circle.fill", .blue, model.breakdown.originals)
                total("Separations", "waveform", .indigo, model.breakdown.separations)
                total("Performances", "mic.fill", .red, model.breakdown.performances)
                total("Models", "shippingbox", .teal, model.breakdown.models)
                total("Temporary", "clock.arrow.circlepath", .gray, model.breakdown.temporary)
                LabeledContent("Total", value: StorageCapacity.formatted(model.breakdown.total))
                    .font(.body.weight(.semibold))
            }

            Section {
                total("Practice & analysis", "text.book.closed", .green, model.breakdown.analysis)
            } footer: {
                Text("Loops, practice settings, lyrics, chords, and beat grids, stored beside each song. Counted inside Originals and Separations above, and backed up — nothing can regenerate it.")
            }

            evictionSection

            if model.quarantinedCount > 0 {
                Section {
                    Button(role: .destructive) {
                        Task { await model.emptyQuarantine(store: store) }
                    } label: {
                        Label(
                            "Empty Quarantine (\(model.quarantinedCount))",
                            systemImage: "trash"
                        )
                    }
                } header: {
                    Text("Quarantine")
                } footer: {
                    Text("Folders Atarang could not make sense of, moved aside rather than deleted. They are counted under Temporary.")
                }
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh(store: store) }
        .refreshable { await model.refresh(store: store) }
        .confirmationDialog(
            "Remove downloaded audio?",
            isPresented: Binding(
                get: { evictionScope != nil },
                set: { if !$0 { evictionScope = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Audio", role: .destructive) {
                let candidates = evictionScope == .separated
                    ? model.separatedEvictable
                    : model.evictable
                evictionScope = nil
                Task { await model.evict(candidates, store: store) }
            }
            Button("Cancel", role: .cancel) { evictionScope = nil }
        } message: {
            Text("Only the downloaded audio is removed. Each song keeps its practice settings, loops, and analysis, and separating it again downloads the audio from its source.")
        }
    }

    @ViewBuilder
    private var evictionSection: some View {
        if !model.evictable.isEmpty {
            Section {
                if !model.separatedEvictable.isEmpty {
                    Button {
                        evictionScope = .separated
                    } label: {
                        LabeledContent(
                            "Already Separated (\(model.separatedEvictable.count))",
                            value: StorageCapacity.formatted(
                                model.separatedEvictable.reduce(0) { $0 + $1.byteCount }
                            )
                        )
                    }
                }
                Button {
                    evictionScope = .all
                } label: {
                    LabeledContent(
                        "All Downloaded Originals (\(model.evictable.count))",
                        value: StorageCapacity.formatted(model.evictableBytes)
                    )
                }
            } header: {
                Text("Reclaim downloaded audio")
            } footer: {
                Text("Downloaded originals are a cache: they can be fetched again from the source they came from. Removing the audio of songs you have already separated frees the most for the least inconvenience — re-separating one of them will download it again.")
            }
        }
    }

    private func total(
        _ title: String,
        _ systemImage: String,
        _ color: Color,
        _ bytes: Int64
    ) -> some View {
        LabeledContent {
            Text(StorageCapacity.formatted(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Privacy

/// What leaves the device and when, and what iCloud gets. Kept consistent with
/// the README's privacy section on purpose — two statements of the same policy
/// that disagree are worse than one.
struct PrivacySettingsView: View {
    var body: some View {
        Form {
            Section("What leaves this device") {
                privacyRow(
                    "YouTube",
                    "safari",
                    "The URL you paste, to read the video's information and download its audio. Caption tracks use the same connection."
                )
                privacyRow(
                    "lrclib.net",
                    "text.quote",
                    "Only with online lyrics lookup turned on, and only the song title — plus an artist name if you type one. Nothing while it is off."
                )
                privacyRow(
                    "Model downloads",
                    "shippingbox",
                    "The first time you choose an optional separation, its weights are fetched from Hugging Face and checked against a pinned checksum."
                )
            }

            Section {
                Text("There is no Atarang server, no account, and no analytics. Separation, beat detection, chord analysis, recording, and mixing all run on this device.")
            } footer: {
                Text("Diagnostics you export from Settings contain folder identifiers, sizes, and faults — never song titles, source URLs, or filenames.")
            }

            Section("iCloud backup") {
                backupRow("Performances", true, "Your recordings. Nothing can reproduce them.")
                backupRow("Practice & analysis", true, "Loops, settings, lyrics, chords, beats, and your corrections to them.")
                backupRow("Downloaded originals", false, "Re-fetchable from their source.")
                backupRow("Separated stems", false, "Reproducible by separating again.")
                backupRow("Optional models", false, "Re-downloadable and checksum-verified.")
            }
        }
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func privacyRow(_ title: String, _ systemImage: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func backupRow(_ title: String, _ isBackedUp: Bool, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isBackedUp ? "checkmark.icloud.fill" : "xmark.icloud")
                .foregroundStyle(isBackedUp ? Color.green : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Diagnostics

/// What the integrity pass found, and a report the user can send on.
struct DiagnosticsSettingsView: View {
    @ObservedObject var store: HistoryStore
    @Bindable var model: StorageSettingsModel
    @State private var sharePayload: SharePayload?

    var body: some View {
        Form {
            if let report = model.report {
                Section {
                    LabeledContent("Entries", value: "\(report.entries.count)")
                    LabeledContent("Problems", value: "\(report.problems.count)")
                    LabeledContent("Repaired", value: "\(report.repairedCount)")
                    LabeledContent("Quarantined", value: "\(report.quarantinedCount)")
                    LabeledContent(
                        "Checked",
                        value: report.generatedAt.formatted(.dateTime.month().day().hour().minute())
                    )
                } header: {
                    Text("Library check")
                } footer: {
                    Text(
                        report.problems.isEmpty
                            ? "Every song, separation, and performance is intact."
                            : "Recoverable entries had their description rebuilt from the files themselves. Unrecoverable ones were moved to quarantine rather than deleted."
                    )
                }

                if !report.problems.isEmpty {
                    Section("Findings") {
                        ForEach(report.problems) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("\(entry.kind.title) · \(entry.status.label)")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(StorageCapacity.formatted(entry.byteCount))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                if let reason = entry.status.reason {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.folderName)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } else {
                Section {
                    Text("No library check has run yet.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await model.rescan(store: store) }
                } label: {
                    Label("Check Library Again", systemImage: "arrow.clockwise")
                }
                .disabled(model.isWorking)
                Button {
                    exportReport()
                } label: {
                    Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                }
                .disabled(model.report == nil)
            } footer: {
                Text("The exported report lists folder identifiers, sizes, and what was wrong. It contains no song titles, source URLs, or media filenames.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh(store: store) }
        .sheet(item: $sharePayload) { payload in
            ActivityView(items: payload.items)
                .presentationDetents([.medium, .large])
        }
    }

    private func exportReport() {
        guard let report = model.report else { return }
        let text = LibraryIntegrity.diagnosticsText(report)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Atarang Diagnostics.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            sharePayload = SharePayload(items: [url])
        } catch {
            // Nothing to recover: the report is derived and can be exported
            // again. Falling back to the text itself still lets the user send
            // it somewhere.
            sharePayload = SharePayload(items: [text as Any])
        }
    }
}
