import XCTest
import DiscShiftCore
@testable import DiscShift

private func show(_ id: Int, _ year: String) -> CatalogShow {
    try! JSONDecoder().decode(CatalogShow.self, from: Data("{\"id\":\(id),\"name\":\"Example Series\",\"premiered\":\"\(year)-01-01\"}".utf8))
}
private let catalog: [CatalogEpisode] = try! JSONDecoder().decode([CatalogEpisode].self, from: Data(#"[{"id":11,"name":"The Beginning","season":1,"number":1},{"id":12,"name":"A New Day","season":1,"number":2},{"id":21,"name":"Return","season":2,"number":1}]"#.utf8))
private struct StubCatalog: ShowMetadataProviding {
    var shows: [CatalogShow] = [show(1, "1978"), show(2, "2020")]
    var failsSearch = false
    var failsEpisodes = false
    var delays = false
    func search(query: String) async throws -> [CatalogShow] {
        if delays && query == "old" { try? await Task.sleep(nanoseconds: 150_000_000); return [show(9, "1999"), show(10, "2000")] }
        if failsSearch { throw URLError(.notConnectedToInternet) }
        return shows
    }
    func episodes(showID: Int) async throws -> [CatalogEpisode] {
        if delays { try? await Task.sleep(nanoseconds: 150_000_000) }
        if failsEpisodes { throw URLError(.timedOut) }
        return catalog
    }
}

final class IdentificationTests: XCTestCase {
    @MainActor private func model(_ provider: any ShowMetadataProviding = StubCatalog()) -> AppModel {
        let defaults = UserDefaults(suiteName: "DiscShiftMetadataTests-" + UUID().uuidString)!
        defaults.set(false, forKey: "automaticShowLookup")
        let model = AppModel(defaults: defaults, discoverMountedDiscs: false, metadataProvider: provider)
        model.setSource(FileManager.default.temporaryDirectory)
        model.executable = "/bin/sh"
        model.destination = FileManager.default.temporaryDirectory.appendingPathComponent("Library")
        model.choices = [1, 2].map { EpisodeChoice(title: DiscTitle(index: $0, duration: 3000, chapters: 10), selected: true, episode: $0) }
        model.step = .identify
        return model
    }
    @MainActor private func settle(_ model: AppModel) async {
        for _ in 0..<5 {
            await model.metadataTask?.value
            if !model.lookingUpShow { return }
        }
        XCTFail("Lookup did not settle")
    }
    @MainActor func testAmbiguousVersionsRequireChoosingShow() async {
        let model = model()
        model.searchQuery = "Example Series"; model.searchShows(); await settle(model)
        XCTAssertEqual(model.showMatches.count, 2)
        XCTAssertNil(model.identifiedShow); XCTAssertTrue(model.series.isEmpty)
        XCTAssertFalse(model.canContinue)
        model.selectShow(model.showMatches[0]); await settle(model)
        XCTAssertEqual(model.series, "Example Series"); XCTAssertEqual(model.year, "1978")
        XCTAssertEqual(model.availableSeasons, [1, 2]); XCTAssertTrue(model.canContinue)
        model.continueWizard(); XCTAssertEqual(model.step, .episodes)
        XCTAssertFalse(model.canExport)
        model.continueWizard(); XCTAssertEqual(model.step, .library)
        XCTAssertEqual(model.episodeMetadata(1)?.name, "The Beginning")
        XCTAssertTrue(model.episodeOrderConfirmed); XCTAssertTrue(model.canExport)
        model.choices[0].episode = 2; XCTAssertFalse(model.episodeOrderConfirmed)
        XCTAssertFalse(model.canExport) // Also duplicates the second assignment.
    }
    @MainActor func testUniqueMatchAutofillsButDoesNotConfirmEpisodeOrder() async {
        let model = model(StubCatalog(shows: [show(1, "1978")]))
        model.searchQuery = "Example Series"; model.searchShows(); await settle(model)
        XCTAssertEqual(model.identifiedShow?.id, 1)
        XCTAssertEqual(model.year, "1978"); XCTAssertFalse(model.episodeOrderConfirmed)
        model.year = "2020"
        XCTAssertTrue(model.currentCatalog.isEmpty); XCTAssertTrue(model.availableSeasons.isEmpty)
        XCTAssertNil(model.matchingShow)
    }
    @MainActor func testOfflineLookupAllowsManualDetails() async {
        let model = model(StubCatalog(failsSearch: true))
        model.searchQuery = "Example Series"; model.searchShows(); await settle(model)
        XCTAssertTrue(model.metadataMessage?.contains("manually") == true)
        model.enterShowManually(); XCTAssertEqual(model.step, .identify)
        XCTAssertTrue(model.enteringShowManually)
        XCTAssertFalse(model.canContinue)
        model.series = "My Series"; XCTAssertTrue(model.canContinue)
        model.continueWizard(); XCTAssertEqual(model.step, .episodes)
        XCTAssertFalse(model.episodeOrderConfirmed)
        model.continueWizard(); XCTAssertEqual(model.step, .library)
        XCTAssertTrue(model.episodeOrderConfirmed); XCTAssertTrue(model.canContinue)
    }
    @MainActor func testEpisodeFailureRetainsShowAndAllowsManualNumbering() async {
        let model = model(StubCatalog(failsEpisodes: true))
        model.selectShow(show(1, "1978")); await settle(model)
        XCTAssertEqual(model.year, "1978"); XCTAssertTrue(model.currentCatalog.isEmpty)
        XCTAssertTrue(model.metadataMessage?.contains("manually") == true)
        XCTAssertTrue(model.canContinue); XCTAssertFalse(model.canExport)
    }
    @MainActor func testStaleSearchCannotReplaceNewResults() async {
        let model = model(StubCatalog(delays: true))
        model.searchQuery = "old"; model.searchShows(); let old = model.metadataTask
        await Task.yield()
        model.searchQuery = "new"; model.searchShows(); await settle(model); await old?.value
        XCTAssertEqual(model.showMatches.map(\.id), [1, 2])
    }
    @MainActor func testSourceChangeDiscardsInFlightEpisodeLookup() async {
        let model = model(StubCatalog(delays: true))
        model.selectShow(show(1, "1978")); let old = model.metadataTask
        await Task.yield()
        model.setSource(FileManager.default.temporaryDirectory.appendingPathComponent("another-source"))
        await old?.value
        XCTAssertNil(model.identifiedShow); XCTAssertTrue(model.catalogEpisodes.isEmpty)
        XCTAssertTrue(model.series.isEmpty); XCTAssertFalse(model.lookingUpShow)
    }
}
