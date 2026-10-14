import Darwin
import Foundation

/// A single-consumer, bounded newline reader for a persistent pipe.
final class SemanticWorkerInput {
    enum Failure: Error { case tooLarge, incomplete, readFailed }

    private let descriptor: Int32
    private let maximumLineBytes: Int
    private var buffer = Data()
    private var bytes = [UInt8](repeating: 0, count: 8192)

    init(descriptor: Int32 = STDIN_FILENO, maximumLineBytes: Int) {
        precondition(maximumLineBytes > 0)
        self.descriptor = descriptor
        self.maximumLineBytes = maximumLineBytes
    }

    func next() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                guard buffer.distance(from: buffer.startIndex, to: newline) < maximumLineBytes else {
                    throw Failure.tooLarge
                }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            guard buffer.count < maximumLineBytes else { throw Failure.tooLarge }
            // FileHandle.read(upToCount:) can wait for the full count or EOF.
            // POSIX read returns available pipe bytes while its writer stays open.
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.readFailed
            }
            if count == 0 {
                guard buffer.isEmpty else { throw Failure.incomplete }
                return nil
            }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}
