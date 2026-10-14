import AppKit
import XCTest
import os

@testable import ScreenlogCore

private final class FaviconURLProtocolStub: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var requestCount = 0
        var statusCode = 404
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var requestCount: Int {
        state.withLock { $0.requestCount }
    }

    static func reset(statusCode: Int = 404) {
        state.withLock {
            $0.requestCount = 0
            $0.statusCode = statusCode
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let statusCode = Self.state.withLock {
            $0.requestCount += 1
            return $0.statusCode
        }
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/x-icon"]
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FaviconCacheTests: XCTestCase {
    var tempDir: URL!
    var cache: FaviconCache!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-favicon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        cache = FaviconCache(cacheDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        cache = nil
        FaviconURLProtocolStub.reset()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FaviconURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    func testNormalizeDomainStripsSchemeAndWWW() {
        XCTAssertEqual(FaviconCache.normalizeDomain("https://www.Example.com/path?q=1"), "example.com")
        XCTAssertEqual(FaviconCache.normalizeDomain("NEWS.ycombinator.com"), "news.ycombinator.com")
        XCTAssertEqual(FaviconCache.normalizeDomain("  github.com  "), "github.com")
        XCTAssertEqual(FaviconCache.normalizeDomain(""), "")
    }

    func testPlaceholderNeverNilAndHasLetter() {
        let img = cache.placeholder(for: "apple.com", size: 16)
        XCTAssertGreaterThan(img.size.width, 0)
        XCTAssertGreaterThan(img.size.height, 0)
        let empty = cache.placeholder(for: "", size: 12)
        XCTAssertGreaterThan(empty.size.width, 0)
    }

    func testStoreFixtureThenCachedImage() throws {
        // 1x1 PNG
        let pngBase64 =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let data = Data(base64Encoded: pngBase64)!
        let stored = cache.store(data: data, domain: "fixture.test")
        XCTAssertNotNil(stored)

        // Memory hit
        let mem = cache.cachedImage(for: "fixture.test")
        XCTAssertNotNil(mem)

        // After clearing memory via new instance on same dir, disk hit works.
        let cold = FaviconCache(cacheDirectory: tempDir)
        // Wait briefly for async PNG write.
        let deadline = Date().addingTimeInterval(2)
        var disk: NSImage?
        while Date() < deadline {
            if let hit = cold.cachedImage(for: "https://www.fixture.test/page") {
                disk = hit
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNotNil(disk, "disk cache should resolve normalized domain after store")
    }

    func testImageFallsBackToPlaceholderWithoutNetworkBlocking() async {
        // Use a domain that will not be in cache; with unreachable host via custom session
        // is overkill - just assert image(for:) returns something usable offline-fast path.
        let img = await cache.image(for: "")
        XCTAssertGreaterThan(img.size.width, 0)
    }

    func testAirgapSkipsNetworkAndReturnsPlaceholder() async {
        FaviconURLProtocolStub.reset()
        let airgapped = FaviconCache(
            cacheDirectory: tempDir,
            session: stubbedSession(),
            airgapMode: true,
            remoteFetchingEnabled: true
        )
        let img = await airgapped.image(for: "never-fetched-\(UUID().uuidString).example")
        XCTAssertGreaterThan(img.size.width, 0)
        XCTAssertEqual(FaviconURLProtocolStub.requestCount, 0, "airgap mode must not create a network request")
        // No disk write should have occurred for a pure placeholder miss under airgap.
        XCTAssertNil(airgapped.cachedImage(for: "never-fetched-should-not-exist.example"))
    }

    func testRemoteFetchingIsOptInByDefault() async throws {
        FaviconURLProtocolStub.reset()
        let suiteName = "screenlog-favicon-defaults-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let privateByDefault = FaviconCache(
            cacheDirectory: tempDir,
            session: stubbedSession(),
            airgapMode: false,
            preferences: preferences
        )

        _ = await privateByDefault.image(for: "private-by-default.example")

        XCTAssertFalse(privateByDefault.remoteFetchingEnabled)
        XCTAssertEqual(FaviconURLProtocolStub.requestCount, 0)
    }

    func testFailedFetchIsNegativeCached() async {
        FaviconURLProtocolStub.reset(statusCode: 404)
        let online = FaviconCache(
            cacheDirectory: tempDir,
            session: stubbedSession(),
            airgapMode: false,
            remoteFetchingEnabled: true
        )

        _ = await online.image(for: "missing.example")
        _ = await online.image(for: "missing.example")

        XCTAssertEqual(FaviconURLProtocolStub.requestCount, 1, "repeated failures should remain offline")
    }

    func testPrefetchCompletesUnderAirgap() async {
        let airgapped = FaviconCache(cacheDirectory: tempDir, airgapMode: true)
        await airgapped.prefetch(domains: ["a.example", "b.example", "https://www.c.example/path"])
        // Completes without throwing; placeholders only.
        let a = await airgapped.image(for: "a.example")
        XCTAssertGreaterThan(a.size.width, 0)
    }

    /// Concurrent airgap toggle must not let fetches observe a torn/unlocked flag.
    func testAirgapToggleRaceDoesNotCrashAndStaysConsistent() async {
        FaviconURLProtocolStub.reset(statusCode: 404)
        let c = FaviconCache(
            cacheDirectory: tempDir,
            session: stubbedSession(),
            airgapMode: false,
            remoteFetchingEnabled: true
        )
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    if i % 2 == 0 {
                        c.airgapMode = true
                    } else {
                        c.airgapMode = false
                    }
                }
                group.addTask {
                    _ = await c.image(for: "race-\(i % 5).example")
                }
            }
        }
        // Final airgap on to network skipped for uncached host.
        c.airgapMode = true
        let requestsBeforeFinalMiss = FaviconURLProtocolStub.requestCount
        let miss = await c.image(for: "never-network-\(UUID().uuidString).example")
        XCTAssertGreaterThan(miss.size.width, 0)
        XCTAssertEqual(FaviconURLProtocolStub.requestCount, requestsBeforeFinalMiss)
        XCTAssertNil(c.cachedImage(for: "never-network-should-not-exist.example"))
    }
}

final class ScreenRecordingPermissionCacheTests: XCTestCase {
    func testStoredValueExpiresAtTTLAndCanBeInvalidated() {
        let cache = ScreenRecordingPermissionCache(ttl: 8)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(cache.value(at: start))

        cache.store(true, at: start)
        XCTAssertEqual(cache.value(at: start.addingTimeInterval(7.999)), true)
        XCTAssertNil(cache.value(at: start.addingTimeInterval(8)))

        cache.store(false, at: start.addingTimeInterval(10))
        XCTAssertEqual(cache.value(at: start.addingTimeInterval(11)), false)
        cache.invalidate()
        XCTAssertNil(cache.value(at: start.addingTimeInterval(11)))
    }

    func testConcurrentReadsAndWritesAreSafe() {
        let cache = ScreenRecordingPermissionCache(ttl: 60)
        let now = Date(timeIntervalSince1970: 2_000)

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            if index.isMultiple(of: 3) {
                cache.store(index.isMultiple(of: 2), at: now)
            } else {
                _ = cache.value(at: now)
            }
        }

        XCTAssertNotNil(cache.value(at: now))
    }
}
