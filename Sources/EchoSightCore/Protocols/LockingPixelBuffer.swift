import CoreVideo

/// Sendable-safe wrapper around a `CVPixelBuffer`.
///
/// `CVPixelBuffer` is a CoreFoundation type whose thread safety isn't expressible
/// in Swift's type system. Apple's Vision and AVFoundation APIs routinely pass it
/// across threads, so the unchecked Sendable conformance matches established
/// framework behavior. Pixel-data access is funneled through
/// `withLockedBaseAddress`, which pairs `CVPixelBufferLockBaseAddress` with a
/// matching unlock under `defer` so callers cannot forget to unlock.
public struct LockingPixelBuffer: @unchecked Sendable {

    public let buffer: CVPixelBuffer

    public init(_ buffer: CVPixelBuffer) {
        self.buffer = buffer
    }

    public var width: Int { CVPixelBufferGetWidth(buffer) }
    public var height: Int { CVPixelBufferGetHeight(buffer) }
    public var pixelFormat: OSType { CVPixelBufferGetPixelFormatType(buffer) }
    public var bytesPerRow: Int { CVPixelBufferGetBytesPerRow(buffer) }

    /// Locks the buffer's base address for the duration of `body` and returns
    /// the closure's result. Always unlocks, even if `body` throws.
    ///
    /// - Parameter readOnly: When `true` (default), locks with
    ///   `.readOnly` for lower cost; callers must not mutate the returned
    ///   pointer. Set to `false` when writing into the buffer.
    public func withLockedBaseAddress<T>(
        readOnly: Bool = true,
        _ body: (UnsafeMutableRawPointer?) throws -> T
    ) rethrows -> T {
        let flags: CVPixelBufferLockFlags = readOnly ? .readOnly : []
        CVPixelBufferLockBaseAddress(buffer, flags)
        defer { CVPixelBufferUnlockBaseAddress(buffer, flags) }
        return try body(CVPixelBufferGetBaseAddress(buffer))
    }
}
