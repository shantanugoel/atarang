import CoreML
import CryptoKit
import Foundation
import ZIPFoundation

enum SeparationModelArtifact: Sendable {
    case coreML(URL)
    case onnx(URL)
}

enum ModelAssetError: LocalizedError {
    case invalidDownload(SeparationModelKind)
    case checksumMismatch(SeparationModelKind)
    case archiveMissingModel

    var errorDescription: String? {
        switch self {
        case .invalidDownload(let model):
            "The \(model.title) model download was not a valid file."
        case .checksumMismatch(let model):
            "The \(model.title) model download failed its security check. Please try again."
        case .archiveMissingModel:
            "The downloaded MDX23C archive did not contain its Core ML model."
        }
    }
}

/// Serializes first-use downloads and keeps large optional model weights out of the app bundle.
actor ModelAssetStore {
    static let shared = ModelAssetStore()

    typealias Progress = @MainActor @Sendable (_ status: String, _ fraction: Double) -> Void

    func artifact(
        for model: SeparationModelKind,
        progress: @escaping Progress
    ) async throws -> SeparationModelArtifact {
        if model == .htdemucs {
            guard let url = Bundle.main.url(
                forResource: model.resourceName,
                withExtension: "mlmodelc"
            ) ?? Bundle.main.url(forResource: model.resourceName, withExtension: "mlpackage") else {
                throw StemSeparatorError.modelNotFound(model)
            }
            return .coreML(url)
        }

        let directory = try modelsDirectory().appendingPathComponent(model.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        switch model {
        case .htdemucs:
            fatalError("Handled above")
        case .htdemucs6s:
            let target = directory.appendingPathComponent("htdemucs_6s_fp16weights.onnx")
            if !FileManager.default.fileExists(atPath: target.path) {
                await progress("Downloading \(model.title) (136 MB)…", 0.04)
                try await installFile(for: model, target: target)
            }
            return .onnx(target)
        case .kimVocals:
            let target = directory.appendingPathComponent("Kim_Vocal_2.onnx")
            if !FileManager.default.fileExists(atPath: target.path) {
                await progress("Downloading \(model.title) (67 MB)…", 0.04)
                try await installFile(for: model, target: target)
            }
            return .onnx(target)
        case .mdx23cInstVocHQ:
            let compiled = directory.appendingPathComponent("MDX23C_InstVoc_HQ.mlmodelc", isDirectory: true)
            if !FileManager.default.fileExists(atPath: compiled.path) {
                await progress("Downloading \(model.title) (40 MB)…", 0.04)
                try await installAndCompileMDX(for: model, directory: directory, destination: compiled, progress: progress)
            }
            return .coreML(compiled)
        }
    }

    nonisolated static func isInstalled(_ model: SeparationModelKind) -> Bool {
        if model == .htdemucs { return true }
        guard let root = try? modelsDirectory() else { return false }
        let directory = root.appendingPathComponent(model.rawValue, isDirectory: true)
        let name: String
        switch model {
        case .htdemucs: return true
        case .htdemucs6s: name = "htdemucs_6s_fp16weights.onnx"
        case .kimVocals: name = "Kim_Vocal_2.onnx"
        case .mdx23cInstVocHQ: name = "MDX23C_InstVoc_HQ.mlmodelc"
        }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    private func installFile(for model: SeparationModelKind, target: URL) async throws {
        let descriptor = try descriptor(for: model)
        let downloaded = try await download(descriptor.url, for: model)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try verify(downloaded, sha256: descriptor.sha256, model: model)
        try FileManager.default.moveItem(at: downloaded, to: target)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableTarget = target
        try? mutableTarget.setResourceValues(values)
    }

    private func installAndCompileMDX(
        for model: SeparationModelKind,
        directory: URL,
        destination: URL,
        progress: @escaping Progress
    ) async throws {
        let descriptor = try descriptor(for: model)
        let downloaded = try await download(descriptor.url, for: model)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try verify(downloaded, sha256: descriptor.sha256, model: model)

        await progress("Installing \(model.title)…", 0.08)
        let extraction = directory.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extraction) }
        try FileManager.default.unzipItem(at: downloaded, to: extraction)

        guard let package = try findFile(withExtension: "mlpackage", below: extraction) else {
            throw ModelAssetError.archiveMissingModel
        }
        let compiled = try await Task.detached(priority: .userInitiated) {
            try MLModel.compileModel(at: package)
        }.value
        try FileManager.default.copyItem(at: compiled, to: destination)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destination
        try? mutableDestination.setResourceValues(values)
    }

    private func download(_ url: URL, for model: SeparationModelKind) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 1_000_000 else {
            throw ModelAssetError.invalidDownload(model)
        }
        let retained = FileManager.default.temporaryDirectory
            .appendingPathComponent("Atarang-model-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: temporary, to: retained)
        return retained
    }

    private func verify(_ url: URL, sha256 expected: String, model: SeparationModelKind) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw ModelAssetError.checksumMismatch(model) }
    }

    private func findFile(withExtension extensionName: String, below directory: URL) throws -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.pathExtension == extensionName {
            return url
        }
        return nil
    }

    private struct Descriptor {
        let url: URL
        let sha256: String
    }

    private func descriptor(for model: SeparationModelKind) throws -> Descriptor {
        switch model {
        case .htdemucs:
            throw StemSeparatorError.modelNotFound(model)
        case .htdemucs6s:
            return Descriptor(
                url: URL(string: "https://huggingface.co/StemSplitio/htdemucs-6s-onnx/resolve/49df9b6989cf2150840ea65b0bef77a2e471b678/htdemucs_6s_fp16weights.onnx")!,
                sha256: "7ce55792e2231c93fbf92de95f5fd5b3a5e6c89f7db690dfd693e8f1dce56869"
            )
        case .mdx23cInstVocHQ:
            return Descriptor(
                url: URL(string: "https://huggingface.co/huggingsounds/nubeaudio-mdx/resolve/a133c157760773700ecbdaadcba755d7e94739c3/mdx23c_instvoc_hq.mlpackage.zip")!,
                sha256: "c1d4c475f1d43b64f9e48b8b8e5defe6f41ead6289d1feb9da6480c25246c674"
            )
        case .kimVocals:
            return Descriptor(
                url: URL(string: "https://huggingface.co/nomadkaraoke/public_uvr_models/resolve/999821733f252623504d13eca10cc3cc89c6108e/Kim_Vocal_2.onnx")!,
                sha256: "ce74ef3b6a6024ce44211a07be9cf8bc6d87728cc852a68ab34eb8e58cde9c8b"
            )
        }
    }

    private nonisolated static func modelsDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Models", isDirectory: true)
    }

    private func modelsDirectory() throws -> URL { try Self.modelsDirectory() }
}
