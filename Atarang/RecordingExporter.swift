import AVFoundation
import Foundation

enum RecordingExporter {
    static func export(take: RecordedTake) async throws -> URL {
        let microphoneAsset = AVURLAsset(url: take.microphoneURL)
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
        backingParameters.setVolume(0.72, at: .zero)
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [microphoneParameters, backingParameters]

        let outputURL = take.microphoneURL
            .deletingLastPathComponent()
            .appendingPathComponent("Atarang Performance")
            .appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: outputURL)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw ExportError.couldNotCreateExporter }
        exporter.audioMix = audioMix

        #if os(iOS)
        if #available(iOS 18.0, *) {
            try await exporter.export(to: outputURL, as: .m4a)
            return outputURL
        }
        #endif
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously { continuation.resume() }
        }
        switch exporter.status {
        case .completed: return outputURL
        case .failed: throw exporter.error ?? ExportError.exportFailed
        case .cancelled: throw CancellationError()
        default: throw ExportError.exportFailed
        }
    }

}

private enum ExportError: LocalizedError {
    case missingAudio
    case couldNotCreateMix
    case couldNotCreateExporter
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .missingAudio: "The recorded performance audio is missing."
        case .couldNotCreateMix: "Atarang could not create the performance mix."
        case .couldNotCreateExporter: "This device could not create an M4A exporter."
        case .exportFailed: "The shareable M4A export failed."
        }
    }
}
