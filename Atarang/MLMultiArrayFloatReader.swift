import CoreML
import Foundation

/// Reads an MLMultiArray in logical row-major order while respecting the
/// physical strides supplied by Core ML. Model outputs are not guaranteed to
/// be contiguous, even when their logical shape is unchanged.
struct MLMultiArrayFloatReader {
    private let dataType: MLMultiArrayDataType
    private let pointer: UnsafeMutableRawPointer
    private let shape: [Int]
    private let strides: [Int]
    /// Whether logical order and physical order agree, so a range can be read
    /// as a plain run of memory. Separation outputs are millions of values, and
    /// the per-element index arithmetic below costs more than the copy it
    /// avoids when this holds.
    let isContiguous: Bool

    let count: Int

    init(_ array: MLMultiArray) {
        dataType = array.dataType
        pointer = array.dataPointer
        shape = array.shape.map(\.intValue)
        strides = array.strides.map(\.intValue)
        count = array.count

        var expected = 1
        var contiguous = true
        for dimension in shape.indices.reversed() {
            if strides[dimension] != expected { contiguous = false; break }
            expected *= shape[dimension]
        }
        isContiguous = contiguous && !shape.isEmpty
    }

    func value(at logicalIndex: Int) -> Float {
        precondition(logicalIndex >= 0 && logicalIndex < count)
        var physicalOffset = logicalIndex
        if !isContiguous {
            var remaining = logicalIndex
            physicalOffset = 0
            for dimension in shape.indices.reversed() {
                let size = shape[dimension]
                guard size > 0 else { return 0 }
                physicalOffset += (remaining % size) * strides[dimension]
                remaining /= size
            }
        }
        return value(atPhysical: physicalOffset)
    }

    func values() -> [Float] {
        var result = [Float](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { copy(0..<count, into: $0.baseAddress!) }
        return result
    }

    /// Presents `range` as a run of floats, without copying when the array is
    /// already contiguous float32 — which is what every separation model here
    /// returns. `scratch` is grown as needed and reused across chunks
    /// otherwise.
    func withValues<R>(
        in range: Range<Int>,
        scratch: inout [Float],
        _ body: (UnsafePointer<Float>) throws -> R
    ) rethrows -> R {
        precondition(range.lowerBound >= 0 && range.upperBound <= count)
        if isContiguous, dataType == .float32 {
            let base = pointer.assumingMemoryBound(to: Float.self)
            return try body(base + range.lowerBound)
        }
        if scratch.count != range.count {
            scratch = [Float](repeating: 0, count: range.count)
        }
        return try scratch.withUnsafeMutableBufferPointer { buffer in
            copy(range, into: buffer.baseAddress!)
            return try body(buffer.baseAddress!)
        }
    }

    private func copy(_ range: Range<Int>, into destination: UnsafeMutablePointer<Float>) {
        guard !range.isEmpty else { return }
        if isContiguous {
            switch dataType {
            case .float32:
                destination.update(
                    from: pointer.assumingMemoryBound(to: Float.self) + range.lowerBound,
                    count: range.count
                )
                return
            case .float16:
                let source = pointer.assumingMemoryBound(to: Float16.self)
                for offset in 0..<range.count {
                    destination[offset] = Float(source[range.lowerBound + offset])
                }
                return
            case .double:
                let source = pointer.assumingMemoryBound(to: Double.self)
                for offset in 0..<range.count {
                    destination[offset] = Float(source[range.lowerBound + offset])
                }
                return
            default:
                break
            }
        }
        for offset in 0..<range.count {
            destination[offset] = value(at: range.lowerBound + offset)
        }
    }

    private func value(atPhysical offset: Int) -> Float {
        switch dataType {
        case .float16:
            return Float(pointer.assumingMemoryBound(to: Float16.self)[offset])
        case .float32:
            return pointer.assumingMemoryBound(to: Float.self)[offset]
        case .double:
            return Float(pointer.assumingMemoryBound(to: Double.self)[offset])
        default:
            return 0
        }
    }
}
