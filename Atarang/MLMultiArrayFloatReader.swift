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

    let count: Int

    init(_ array: MLMultiArray) {
        dataType = array.dataType
        pointer = array.dataPointer
        shape = array.shape.map(\.intValue)
        strides = array.strides.map(\.intValue)
        count = array.count
    }

    func value(at logicalIndex: Int) -> Float {
        precondition(logicalIndex >= 0 && logicalIndex < count)
        var remaining = logicalIndex
        var physicalOffset = 0
        for dimension in shape.indices.reversed() {
            let size = shape[dimension]
            guard size > 0 else { return 0 }
            physicalOffset += (remaining % size) * strides[dimension]
            remaining /= size
        }

        switch dataType {
        case .float16:
            return Float(
                pointer.assumingMemoryBound(to: Float16.self)[physicalOffset]
            )
        case .float32:
            return pointer.assumingMemoryBound(to: Float.self)[physicalOffset]
        case .double:
            return Float(
                pointer.assumingMemoryBound(to: Double.self)[physicalOffset]
            )
        default:
            return 0
        }
    }

    func values() -> [Float] {
        (0..<count).map(value(at:))
    }
}
