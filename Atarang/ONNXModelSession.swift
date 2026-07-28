import Foundation
import OnnxRuntimeBindings

/// Synchronization invariant: every stored property is a `let` assigned during
/// `init` and never mutated afterwards. `ORTSession.run` is safe to call
/// concurrently on one session, and the separation pipeline runs one inference
/// at a time regardless.
final class ONNXModelSession: @unchecked Sendable {
    enum ExecutionBackend: Equatable {
        case automatic
        case cpu
    }

    private let session: ORTSession
    private let inputNames: [String]
    private let outputNames: [String]

    init(modelURL: URL, executionBackend: ExecutionBackend = .automatic) throws {
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        if executionBackend == .automatic, ORTIsCoreMLExecutionProviderAvailable() {
            let coreML = ORTCoreMLExecutionProviderOptions()
            coreML.enableOnSubgraphs = false
            coreML.onlyAllowStaticInputShapes = true
            try? options.appendCoreMLExecutionProvider(with: coreML)
        } else {
            // Keep large models within iOS's memory budget. More ORT worker
            // threads increase the peak scratch allocation substantially.
            try options.setIntraOpNumThreads(2)
        }
        session = try ORTSession(
            env: environment,
            modelPath: modelURL.path,
            sessionOptions: options
        )
        inputNames = try session.inputNames()
        outputNames = try session.outputNames()
    }

    /// Runs the model and hands the output to `consume` in place.
    ///
    /// Separation outputs are tens of megabytes, so the caller decides what to
    /// keep rather than always receiving a fresh `Array`: the MDX models fold
    /// two runs into one accumulator, and the 6-stem model de-interleaves
    /// straight out of the tensor.
    @discardableResult
    func run<R>(
        inputName: String,
        outputName: String,
        values: UnsafeBufferPointer<Float>,
        shape: [NSNumber],
        consume: (UnsafeBufferPointer<Float>) throws -> R
    ) throws -> R {
        let byteCount = values.count * MemoryLayout<Float>.size
        let inputData = NSMutableData(bytes: values.baseAddress!, length: byteCount)
        let input = try ORTValue(
            tensorData: inputData,
            elementType: .float,
            shape: shape
        )
        let outputs = try session.run(
            withInputs: [inputName: input],
            outputNames: [outputName],
            runOptions: nil
        )
        guard let output = outputs[outputName] else {
            throw StemSeparatorError.inferenceFailed("The ONNX model returned no '\(outputName)' output.")
        }
        let data = try output.tensorData()
        let count = data.length / MemoryLayout<Float>.size
        let floats = data.bytes.bindMemory(to: Float.self, capacity: count)
        return try withExtendedLifetime(output) {
            try consume(UnsafeBufferPointer(start: floats, count: count))
        }
    }

    func run(
        inputName: String,
        outputName: String,
        values: [Float],
        shape: [NSNumber]
    ) throws -> [Float] {
        try values.withUnsafeBufferPointer { input in
            try run(
                inputName: inputName,
                outputName: outputName,
                values: input,
                shape: shape
            ) { Array($0) }
        }
    }

    @discardableResult
    func runFirst<R>(
        values: UnsafeBufferPointer<Float>,
        shape: [NSNumber],
        consume: (UnsafeBufferPointer<Float>) throws -> R
    ) throws -> R {
        guard let inputName = inputNames.first, let outputName = outputNames.first else {
            throw StemSeparatorError.inferenceFailed("The ONNX model has no audio input or output.")
        }
        return try run(
            inputName: inputName,
            outputName: outputName,
            values: values,
            shape: shape,
            consume: consume
        )
    }
}
