import AVFoundation
import Accelerate
import Foundation
import OSLog

/// A fixed-resolution amplitude overview of a whole song, drawn behind the
/// transport timeline.
///
/// Deliberately coarse and deliberately static. It exists so the user can
/// recognise the shape of the song — where the verse stops and the chorus
/// starts — well enough to drop the playhead near the right place before
/// listening. It is not a zoomable editor waveform, and nothing in the app
/// depends on its precision.
struct WaveformSummary: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    /// Enough detail to see structure on a 6.9" screen, small enough that the
    /// cache file stays a couple of kilobytes.
    static let bucketCount = 480

    var schemaVersion: Int
    /// Normalised so the loudest bucket is 1. Always `bucketCount` long.
    var peaks: [Float]

    init(peaks: [Float]) {
        schemaVersion = Self.currentSchemaVersion
        self.peaks = peaks
    }
}

/// Computes and caches one `WaveformSummary` per separation.
///
/// The cache lives beside the stems, so it is removed with them and is
/// regenerated after a re-separation rather than surviving as a stale picture
/// of a mix that no longer exists.
actor WaveformStore {
    static let shared = WaveformStore()

    static let filename = "waveform.json"

    private let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Waveform"
    )
    /// Tracks already being measured, so switching stages or rotating the
    /// device cannot start a second pass over the same files.
    private var inFlight: [UUID: Task<WaveformSummary?, Never>] = [:]

    func summary(for track: LocalTrack) async -> WaveformSummary? {
        if let existing = inFlight[track.id] { return await existing.value }
        let files = track.separationModel.stems.compactMap { track.files[$0] }
        guard let folder = files.first?.deletingLastPathComponent() else { return nil }
        let cacheURL = folder.appendingPathComponent(Self.filename)

        if let cached = try? LibraryMetadata.read(WaveformSummary.self, from: cacheURL),
           cached.schemaVersion == WaveformSummary.currentSchemaVersion,
           cached.peaks.count == WaveformSummary.bucketCount {
            return cached
        }

        let task = Task<WaveformSummary?, Never>(priority: .utility) {
            guard let summary = Self.measure(files: files) else { return nil }
            do { try LibraryMetadata.write(summary, to: cacheURL) }
            catch {
                // A missing cache costs one recomputation, not a broken screen.
                self.logger.warning(
                    "Could not cache the waveform overview: \(error.localizedDescription, privacy: .public)"
                )
            }
            return summary
        }
        inFlight[track.id] = task
        let summary = await task.value
        inFlight[track.id] = nil
        return summary
    }

    /// Reads every stem once and combines them per bucket.
    ///
    /// Buckets hold RMS rather than peak: a peak overview of a drum stem is a
    /// solid block, which tells the user nothing about song structure. Stems
    /// combine as the square root of the sum of squares, which is what
    /// uncorrelated sources actually do, rather than a plain sum that would
    /// clip every bucket to the same height.
    nonisolated static func measure(files: [URL]) -> WaveformSummary? {
        guard !files.isEmpty else { return nil }
        var energy = [Float](repeating: 0, count: WaveformSummary.bucketCount)
        var measuredAny = false

        for url in files {
            guard let file = try? AVAudioFile(forReading: url),
                  file.length > 0 else { continue }
            let format = file.processingFormat
            let totalFrames = file.length
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 65_536
            ) else { continue }

            var bucketSums = [Float](repeating: 0, count: WaveformSummary.bucketCount)
            var bucketCounts = [Float](repeating: 0, count: WaveformSummary.bucketCount)
            var frameIndex: AVAudioFramePosition = 0

            while frameIndex < totalFrames {
                do { try file.read(into: buffer) } catch { break }
                let frames = Int(buffer.frameLength)
                guard frames > 0, let channels = buffer.floatChannelData else { break }
                let channelCount = Int(format.channelCount)

                // One bucket usually spans many chunks, so the whole chunk maps
                // to a small run of buckets; splitting it at bucket edges keeps
                // the arithmetic to a handful of vDSP calls per chunk.
                var offset = 0
                while offset < frames {
                    let absolute = frameIndex + AVAudioFramePosition(offset)
                    let bucket = min(
                        WaveformSummary.bucketCount - 1,
                        Int(
                            Double(absolute) / Double(totalFrames)
                                * Double(WaveformSummary.bucketCount)
                        )
                    )
                    let bucketEndFrame = AVAudioFramePosition(
                        (Double(bucket + 1) / Double(WaveformSummary.bucketCount))
                            * Double(totalFrames)
                    )
                    let available = frames - offset
                    let span = max(
                        1,
                        min(available, Int(max(1, bucketEndFrame - absolute)))
                    )
                    for channel in 0..<channelCount {
                        var meanSquare: Float = 0
                        vDSP_measqv(
                            channels[channel] + offset,
                            1,
                            &meanSquare,
                            vDSP_Length(span)
                        )
                        bucketSums[bucket] += meanSquare * Float(span)
                    }
                    bucketCounts[bucket] += Float(span * channelCount)
                    offset += span
                }
                frameIndex += AVAudioFramePosition(frames)
            }

            guard frameIndex > 0 else { continue }
            measuredAny = true
            for bucket in 0..<WaveformSummary.bucketCount where bucketCounts[bucket] > 0 {
                // Mean square for this stem in this bucket; energies add.
                energy[bucket] += bucketSums[bucket] / bucketCounts[bucket]
            }
        }

        guard measuredAny else { return nil }
        var peaks = energy.map { $0 > 0 ? sqrt($0) : 0 }
        let loudest = peaks.max() ?? 0
        if loudest > 0 {
            peaks = peaks.map { $0 / loudest }
        }
        return WaveformSummary(peaks: peaks)
    }
}
