import Foundation
import OnnxRuntimeBindings

final class ONNXModelSession: @unchecked Sendable {
    private let session: ORTSession
    private let inputNames: [String]
    private let outputNames: [String]

    init(modelURL: URL) throws {
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        if ORTIsCoreMLExecutionProviderAvailable() {
            let coreML = ORTCoreMLExecutionProviderOptions()
            coreML.enableOnSubgraphs = true
            try? options.appendCoreMLExecutionProvider(with: coreML)
        }
        session = try ORTSession(
            env: environment,
            modelPath: modelURL.path,
            sessionOptions: options
        )
        inputNames = try session.inputNames()
        outputNames = try session.outputNames()
    }

    func run(
        inputName: String,
        outputName: String,
        values: [Float],
        shape: [NSNumber]
    ) throws -> [Float] {
        let byteCount = values.count * MemoryLayout<Float>.size
        let inputData = values.withUnsafeBytes { bytes in
            NSMutableData(bytes: bytes.baseAddress!, length: byteCount)
        }
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
        let values = data.bytes.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: values, count: count))
    }

    func runFirst(values: [Float], shape: [NSNumber]) throws -> [Float] {
        guard let inputName = inputNames.first, let outputName = outputNames.first else {
            throw StemSeparatorError.inferenceFailed("The ONNX model has no audio input or output.")
        }
        return try run(
            inputName: inputName,
            outputName: outputName,
            values: values,
            shape: shape
        )
    }
}
