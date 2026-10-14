import Darwin
import Foundation
import XCTest

final class SemanticWorkerInputTests: XCTestCase {
    func testCompleteLinesArriveWhileWriterRemainsOpen() async throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        let input = descriptors[0]
        let output = descriptors[1]
        defer { close(input) }
        let received = expectation(description: "complete requests arrive before EOF")
        let reader = Task.detached { () throws -> [Data?] in
            let input = SemanticWorkerInput(descriptor: input, maximumLineBytes: 64)
            let lines = [try input.next(), try input.next()]
            received.fulfill()
            return lines
        }
        let data = Data("first\nsecond\n".utf8)
        XCTAssertEqual(data.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }, data.count)
        await fulfillment(of: [received], timeout: 1)
        // Close even after a regression so a blocked reader can finish.
        close(output)
        let lines = try await reader.value
        XCTAssertEqual(lines, [Data("first".utf8), Data("second".utf8)])
    }

    func testEOFAndSizeLimitsRejectIncompleteOrOversizedRequests() throws {
        for (bytes, limit, shouldFail) in [("short\n", 8, false), ("unfinished", 64, true), ("12345678\n", 8, true)] {
            var descriptors: [Int32] = [0, 0]
            XCTAssertEqual(pipe(&descriptors), 0)
            defer { close(descriptors[0]) }
            let data = Data(bytes.utf8)
            XCTAssertEqual(data.withUnsafeBytes { Darwin.write(descriptors[1], $0.baseAddress, $0.count) }, data.count)
            close(descriptors[1])
            let reader = SemanticWorkerInput(descriptor: descriptors[0], maximumLineBytes: limit)
            if shouldFail {
                XCTAssertThrowsError(try reader.next())
            } else {
                XCTAssertEqual(try reader.next(), Data("short".utf8))
                XCTAssertNil(try reader.next())
            }
        }
    }
}
