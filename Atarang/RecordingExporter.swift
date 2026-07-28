import AVFoundation
import Foundation

enum RecordingExporter {
    static func export(take: RecordedTake) async throws -> URL {
        // The boosted microphone copy alone is the size of the take again, so
        // an export is checked like anything else that writes audio.
        try StorageCapacity.require(
            StorageEstimate.export(duration: take.duration)
                + StorageEstimate.recording(duration: take.duration) / 2,
            for: .export
        )
        let processedMicrophoneURL = try boostedMicrophone(for: take)
        defer {
            if processedMicrophoneURL != take.microphoneURL {
                try? FileManager.default.removeItem(at: processedMicrophoneURL)
            }
        }

        let microphoneAsset = AVURLAsset(url: processedMicrophoneURL)
        let backingAsset = AVURLAsset(url: take.backingURL)
        guard let microphoneTrack = try await microphoneAsset.loadTracks(withMediaType: .audio).first,
              let backingTrack = try await backingAsset.loadTracks(withMediaType: .audio).first else {
            throw ExportError.missingAudio
        }

        let microphoneTimeRange = try await microphoneTrack.load(.timeRange)
        let backingTimeRange = try await backingTrack.load(.timeRange)
        let duration = CMTimeMinimum(microphoneTimeRange.duration, backingTimeRange.duration)
        let composition = AVMutableComposition()
        guard let microphoneCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let backingCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.couldNotCreateMix }

        try microphoneCompositionTrack.insertTimeRange(
            CMTimeRange(start: microphoneTimeRange.start, duration: duration),
            of: microphoneTrack,
            at: .zero
        )
        try backingCompositionTrack.insertTimeRange(
            CMTimeRange(start: backingTimeRange.start, duration: duration),
            of: backingTrack,
            at: .zero
        )

        let microphoneParameters = AVMutableAudioMixInputParameters(track: microphoneCompositionTrack)
        microphoneParameters.setVolume(1, at: .zero)
        let backingParameters = AVMutableAudioMixInputParameters(track: backingCompositionTrack)
        backingParameters.setVolume(min(1, max(0, take.backingLevel)), at: .zero)
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [microphoneParameters, backingParameters]

        let outputURL = take.microphoneURL
            .deletingLastPathComponent()
            .appendingPathComponent("Atarang Performance")
            .appendingPathExtension("m4a")
        let stagingURL = take.microphoneURL
            .deletingLastPathComponent()
            .appendingPathComponent(".mix-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw ExportError.couldNotCreateExporter }
        exporter.audioMix = audioMix

        #if os(iOS)
        if #available(iOS 18.0, *) {
            try await exporter.export(to: stagingURL, as: .m4a)
            try commitExport(from: stagingURL, to: outputURL)
            return outputURL
        }
        #endif
        exporter.outputURL = stagingURL
        exporter.outputFileType = .m4a
        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously { continuation.resume() }
        }
        switch exporter.status {
        case .completed:
            try commitExport(from: stagingURL, to: outputURL)
            return outputURL
        case .failed: throw exporter.error ?? ExportError.exportFailed
        case .cancelled: throw CancellationError()
        default: throw ExportError.exportFailed
        }
    }

    private static func commitExport(from stagingURL: URL, to outputURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: outputURL)
        }
    }

    /// Keeps the original microphone capture untouched and applies the chosen
    /// level only to a temporary export source. Peaks above full scale are
    /// softly limited instead of wrapping or hard clipping.
    private static func boostedMicrophone(for take: RecordedTake) throws -> URL {
        let gain = min(2, max(0, take.microphoneLevel))
        guard gain != 1 else { return take.microphoneURL }

        let source = try AVAudioFile(forReading: take.microphoneURL)
        let format = source.processingFormat
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw ExportError.unsupportedMicrophoneFormat
        }
        let outputURL = take.microphoneURL
            .deletingLastPathComponent()
            .appendingPathComponent("microphone-export.caf")
        try? FileManager.default.removeItem(at: outputURL)
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: source.fileFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 8_192
        ) else { throw ExportError.couldNotProcessMicrophone }

        while source.framePosition < source.length {
            try source.read(into: buffer)
            apply(gain: gain, to: buffer)
            try output.write(from: buffer)
        }
        return outputURL
    }

    private static func apply(gain: Float, to buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        for channelIndex in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channelIndex]
            for frameIndex in 0..<frameCount {
                let amplified = samples[frameIndex] * gain
                samples[frameIndex] = amplified / max(1, abs(amplified))
            }
        }
    }
}

private enum ExportError: LocalizedError {
    case missingAudio
    case couldNotCreateMix
    case couldNotCreateExporter
    case unsupportedMicrophoneFormat
    case couldNotProcessMicrophone
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .missingAudio: "The recorded performance audio is missing."
        case .couldNotCreateMix: "Atarang could not create the performance mix."
        case .couldNotCreateExporter: "This device could not create an M4A exporter."
        case .unsupportedMicrophoneFormat: "The microphone recording uses an unsupported audio format."
        case .couldNotProcessMicrophone: "Atarang could not apply the microphone level."
        case .exportFailed: "The shareable M4A export failed."
        }
    }
}
