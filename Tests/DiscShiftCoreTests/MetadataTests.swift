import XCTest
@testable import DiscShiftCore

final class MetadataTests: XCTestCase {
    func testDiscLabelIsSearchHintNotAnEpisodeAssignment() {
        XCTAssertEqual(DiscLabelHint.clean("THE_SHOW_S02D03"), "THE SHOW")
        XCTAssertEqual(DiscLabelHint.clean("SomeShow (1978) DISC 4"), "Some Show")
        XCTAssertEqual(DiscLabelHint.clean("VIDEO_TS"), "")
        XCTAssertEqual(DiscLabelHint.clean("1899"), "1899")
        let words: Set<String> = ["all", "creature", "great", "and", "small"]
        XCTAssertEqual(DiscLabelHint.query("ALLCREATURESGREATANDSMALLDISC1", words: words), "all creatures great and small")
        XCTAssertEqual(DiscLabelHint.query("UNKNOWNLABELDISC2", words: []), "UNKNOWNLABEL")
    }
    func testCatalogPreservesDifferentShowVersionsAndUnnumberedSpecials() throws {
        let shows = try JSONDecoder().decode([CatalogShow].self, from: Data(#"[{"id":1,"name":"A Show","premiered":"1978-01-08","language":"English","network":{"name":"BBC One","country":{"name":"United Kingdom"}}},{"id":2,"name":"A Show","premiered":"2020-09-01"}]"#.utf8))
        XCTAssertEqual(shows.map(\.year), ["1978", "2020"])
        XCTAssertTrue(shows[0].detail.contains("BBC One"))
        XCTAssertEqual(shows[0].pageURL.absoluteString, "https://www.tvmaze.com/shows/1")
        let special = try JSONDecoder().decode(CatalogEpisode.self, from: Data(#"{"id":3,"name":"Special","season":1,"number":null,"airdate":null,"runtime":null}"#.utf8))
        XCTAssertNil(special.number)
        XCTAssertEqual(special.label, "Special")
    }
    func testClientEncodesSearchAndDecodesBothVersions() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        CatalogURLProtocol.respond = { request in
            XCTAssertEqual(request.url?.host, "api.tvmaze.com")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "A Show & Friends")
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("DiscShift") == true)
            return (200, Data(#"[{"show":{"id":1,"name":"A Show","premiered":"1978-01-08"}},{"show":{"id":2,"name":"A Show","premiered":"2020-09-01"}}]"#.utf8))
        }
        let shows = try await TVMazeClient(session: session).search(query: "A Show & Friends")
        XCTAssertEqual(shows.map(\.year), ["1978", "2020"])
    }
    func testClientReportsServerAndMalformedResponses() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CatalogURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        for (status, data) in [(503, Data()), (200, Data("not JSON".utf8))] {
            CatalogURLProtocol.respond = { _ in (status, data) }
            do { _ = try await TVMazeClient(session: session).search(query: "A Show"); XCTFail("Expected lookup failure") }
            catch { XCTAssertTrue(error.localizedDescription.contains("manually")) }
        }
    }
    func testLiveMetadataLookupWhenExplicitlyEnabled() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DISCSHIFT_TEST_METADATA"] == "1" else { throw XCTSkip("Set DISCSHIFT_TEST_METADATA=1 for live TVMaze verification") }
        let query = DiscLabelHint.query("ALLCREATURESGREATANDSMALLDISC1", words: DiscLabelHint.systemWords)
        let client = TVMazeClient()
        let shows = try await client.search(query: query)
        XCTAssertTrue(shows.contains { $0.year == "1978" })
        XCTAssertTrue(shows.contains { $0.year == "2020" })
        let original = try XCTUnwrap(shows.first { $0.year == "1978" })
        let episodes = try await client.episodes(showID: original.id)
        XCTAssertGreaterThan(episodes.filter { $0.season == 1 && ($0.number ?? 0) > 0 }.count, 3)
    }
}

private final class CatalogURLProtocol: URLProtocol {
    static var respond: ((URLRequest) -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
