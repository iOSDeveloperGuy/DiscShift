import AppKit
import SwiftUI
import DiscShiftCore

struct EpisodeChoice: Identifiable {
    var id: Int { title.id }
    let title: DiscTitle
    var selected: Bool
    var episode: Int
}
struct ExportJob: Identifiable {
    let id = UUID()
    let title: Int
    let episode: Int
    let source: URL
    let output: URL
    let profile: VideoProfile
    let filter: MotionFilter
    let encoder: VideoEncoder
    let container: ExportContainer
    let subtitles: [SubtitleTrack]
    let width: Int
    let height: Int
    var hardwareEncoderID: String?
    var outputBytes: Int64?
    var status = "Waiting"
    var progress = 0.0
}
private struct OrderSnapshot: Equatable {
    struct Assignment: Equatable { let title: Int; let episode: Int; let catalogID: Int? }
    let source: String?
    let series: String
    let year: String
    let season: Int
    let showID: Int?
    let assignments: [Assignment]
}

@MainActor final class AppModel: ObservableObject {
    @Published var choices: [EpisodeChoice] = []
    @Published var jobs: [ExportJob] = []
    @Published var source: URL?
    @Published var destination: URL?
    @Published var series = ""
    @Published var year = ""
    @Published var season = 1
    @Published var firstEpisode = 1
    @Published var profile: VideoProfile = .balanced
    @Published var encoder: VideoEncoder = .hevc
    @Published var container: ExportContainer = .mp4
    @Published private var approvedSubtitleOmissions: [String]?
    @Published var filter: MotionFilter = .adaptive
    @Published var busy = false
    @Published var scanning = false
    @Published var detail = "Choose a DVD to get started"
    @Published var activity = ""
    @Published var error: String?
    @Published var step: WizardStep = .source
    @Published var showingActivity = false
    @Published var showingSetup = false
    let setup: DependencySetup
    @Published var executable: String
    @Published var libraryDirectory: String
    @Published var ejectAfter = false
    @Published var automaticShowLookup: Bool
    @Published var searchQuery = ""
    @Published private(set) var showMatches: [CatalogShow] = []
    @Published private(set) var identifiedShow: CatalogShow?
    @Published private(set) var catalogEpisodes: [CatalogEpisode] = []
    @Published private(set) var lookingUpShow = false
    @Published private(set) var metadataMessage: String?
    @Published var manualEpisodeNumbers = false
    @Published var enteringShowManually = false
    @Published private var confirmedOrder: OrderSnapshot?
    private let metadataProvider: any ShowMetadataProviding
    private(set) var metadataTask: Task<Void, Never>?
    private var metadataRevision = UUID()
    private var identificationCompleted = false
    private let engine = HandBrakeEngine()
    private var observers: [NSObjectProtocol] = []
    private var stopped = false
    private var preventSleep: NSObjectProtocol?
    private let defaults: UserDefaults
    private let discoversMountedDiscs: Bool
    private var retainingShowForNextDisc = false
    private(set) var operationTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, discoverMountedDiscs: Bool = true, metadataProvider: any ShowMetadataProviding = TVMazeClient()) {
        self.defaults = defaults
        self.metadataProvider = metadataProvider
        automaticShowLookup = defaults.object(forKey: "automaticShowLookup") as? Bool ?? true
        discoversMountedDiscs = discoverMountedDiscs
        let readerPath = defaults.string(forKey: "handbrake") ??
            (["/opt/homebrew/bin/HandBrakeCLI", "/usr/local/bin/HandBrakeCLI"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            } ?? "/opt/homebrew/bin/HandBrakeCLI")
        let dvdLibraryPath = defaults.string(forKey: "dvdcss") ?? "/opt/homebrew/lib"
        executable = readerPath; libraryDirectory = dvdLibraryPath
        setup = DependencySetup(readerPath: readerPath, libraryPath: dvdLibraryPath)
        showingSetup = !defaults.bool(forKey: "setupCompleted")
        profile = VideoProfile(rawValue: defaults.string(forKey: "profile") ?? "") ?? .balanced
        encoder = VideoEncoder(rawValue: defaults.string(forKey: "encoder") ?? "") ?? .hevc
        container = ExportContainer(rawValue: defaults.string(forKey: "container") ?? "") ?? .mp4
        filter = MotionFilter(rawValue: defaults.string(forKey: "filter") ?? "") ?? .adaptive
        ejectAfter = defaults.bool(forKey: "ejectAfter")
        if let path = defaults.string(forKey: "destination") { destination = URL(fileURLWithPath: path) }
        guard discoverMountedDiscs else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.discoverDisc() }
            })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let source = self.source,
                          !FileManager.default.fileExists(atPath: source.path) else { return }
                    if self.busy { self.cancel() }
                    self.resetIdentification(preservingShow: false)
                    self.choices = []; self.source = nil; self.step = .source
                    self.detail = "Source disconnected · reconnect your disc to continue"
                }
            })
        discoverDisc()
    }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    var selectedCount: Int { choices.filter(\.selected).count }
    var canExport: Bool {
        !busy && exportHint == nil
    }
    var exportHint: String? {
        guard let source else { return "Open a source to begin." }
        if !FileManager.default.fileExists(atPath: source.path) { return "Reconnect your source to continue." }
        if !FileManager.default.isExecutableFile(atPath: executable) { return "Choose HandBrakeCLI in Settings." }
        if selectedCount == 0 { return "Select at least one title." }
        if let message = libraryValidationMessage { return message }
        if needsSubtitleDecision { return "Choose how to handle picture subtitles, or use MKV to keep them selectable." }
        return nil
    }
    var episodeValidationMessage: String? {
        if series.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the series title to continue." }
        if selectedCount == 0 { return "Select the DVD titles you want to include." }
        let episodes = choices.filter(\.selected).map(\.episode)
        if Set(episodes).count != episodes.count { return "Each title needs a unique episode number. Change an assignment or use Numbering to put them in sequence." }
        if !(0...999).contains(season) || episodes.contains(where: { !(1...999).contains($0) }) { return "Use a season from 0 to 999 and episode numbers from 1 to 999." }
        return nil
    }
    var libraryValidationMessage: String? {
        if let message = episodeValidationMessage { return message }
        if destination == nil { return "Choose the TV library folder Jellyfin scans for your shows." }
        if !episodeOrderConfirmed { return "The episodes have changed. Review and confirm their order again." }
        return nil
    }
    var readerAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable) }
    var canContinue: Bool {
        guard !busy else { return false }
        switch step {
        case .identify: return enteringShowManually ? !series.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : identifiedShow != nil && !lookingUpShow
        case .source: return source != nil && readerAvailable && source.map { FileManager.default.fileExists(atPath: $0.path) } == true
        case .episodes: return episodeValidationMessage == nil
        case .library: return selectedCount > 0 && libraryValidationMessage == nil
        case .review: return canExport
        case .exporting: return false
        }
    }
    func continueWizard() {
        guard canContinue else { return }
        switch step {
        case .source:
            if choices.isEmpty { scan() } else { step = identificationCompleted ? .episodes : .identify }
        case .identify:
            if !enteringShowManually, let show = identifiedShow { series = show.name; year = show.year }
            identificationCompleted = true; step = .episodes
        case .episodes: episodeOrderConfirmed = true; step = .library
        case .library: step = .review
        case .review: export()
        case .exporting: break
        }
    }
    func goBack() {
        guard !busy else { return }
        switch step {
        case .identify: stopMetadataLookup(); step = .source
        case .episodes: step = .identify
        case .library: step = .episodes
        case .review: step = .library
        default: break
        }
    }
    func navigate(to target: WizardStep) {
        guard !busy, step != .exporting, target.rawValue < step.rawValue else { return }
        if target == .source { stopMetadataLookup() }
        step = target
    }
    func startNextDisc() {
        guard !busy else { return }
        if let last = jobs.filter({ $0.status == "Complete" }).map(\.episode).max() { firstEpisode = min(999, last + 1) }
        choices = []; jobs = []; error = nil; step = .source
        confirmedOrder = nil
        retainingShowForNextDisc = true
        discoverDisc()
        detail = source == nil ? "Choose a DVD to get started" : "Ready to scan \(source!.lastPathComponent)"
    }
    var filenamePreview: String? {
        guard let first = choices.first(where: \.selected), !series.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return MediaNaming.relativePath(series: series, year: year, season: season, episode: first.episode, container: container)
    }
    var totalProgress: Double { jobs.isEmpty ? 0 : jobs.map(\.progress).reduce(0, +) / Double(jobs.count) }
    func saveSettings() {
        defaults.set(container.rawValue, forKey: "container")
        defaults.set(encoder.rawValue, forKey: "encoder")
        defaults.set(automaticShowLookup, forKey: "automaticShowLookup")
        defaults.set(executable, forKey: "handbrake")
        defaults.set(libraryDirectory, forKey: "dvdcss")
        defaults.set(profile.rawValue, forKey: "profile")
        defaults.set(filter.rawValue, forKey: "filter")
        defaults.set(ejectAfter, forKey: "ejectAfter")
    }
    func openSetup() {
        guard !busy else { return }
        setup.readerPath = executable; setup.libraryPath = libraryDirectory
        showingSetup = true
    }
    func completeSetup() {
        guard setup.isReady else { return }
        executable = setup.readerPath; libraryDirectory = setup.libraryPath
        if encoder == .hevc && !setup.supportsHEVC { encoder = .h264 }
        if encoder == .h264 && !setup.supportsH264 { encoder = .hevc }
        saveSettings(); defaults.set(true, forKey: "setupCompleted"); showingSetup = false
    }
    func appendLog(_ text: String) { activity = String((activity + text).suffix(120_000)) }
    func discoverDisc() {
        guard discoversMountedDiscs, !busy else { return }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        if let dvd = volumes.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("VIDEO_TS").path) }) {
            if source != dvd { setSource(dvd) }
        }
    }
    func setSource(_ url: URL) {
        guard !busy else { return }
        approvedSubtitleOmissions = nil
        if source != url {
            resetIdentification(preservingShow: retainingShowForNextDisc)
            if !retainingShowForNextDisc {
                series = ""; year = ""; season = 1; firstEpisode = 1
            }
            retainingShowForNextDisc = false
        }
        confirmedOrder = nil
        source = url; choices = []; jobs = []; error = nil; activity = ""; step = .source
        detail = "Ready to scan \(url.lastPathComponent)"
    }
    func chooseSource() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true
        p.message = "Choose your mounted DVD, VIDEO_TS folder, disc image, or video file."
        if p.runModal() == .OK, let url = p.url { setSource(url) }
    }
    func chooseDestination() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.canCreateDirectories = true; p.message = "Choose the TV Shows folder used by Jellyfin."
        if p.runModal() == .OK, let url = p.url {
            destination = url; defaults.set(url.path, forKey: "destination")
        }
    }
    func chooseEngine() {
        let p = NSOpenPanel(); p.message = "Select the HandBrakeCLI executable."
        if p.runModal() == .OK, let url = p.url { executable = url.path; saveSettings() }
    }
    func scan() {
        guard let source, !busy else { return }
        stopMetadataLookup(); confirmedOrder = nil
        busy = true; scanning = true; choices = []; error = nil; step = .source
        detail = "Reading titles and chapters…"; activity = ""
        operationTask = Task { [self] in
            defer { busy = false; scanning = false }
            do {
                try await engine.run(executable: executable, arguments: ["--json", "-i", source.path, "-t", "0", "--scan"],
                                     libraryDirectory: libraryDirectory, event: { [weak self] event in
                    if case .titles(let titles) = event { self?.accept(titles) }
                    if case .scanning(_, let label) = event { self?.detail = label }
                }, log: { [weak self] in self?.appendLog($0) })
                if choices.isEmpty { throw EngineFailure(message: "No readable titles found. Check Activity and the DVD reader setup in Settings.") }
                detail = "\(choices.count) \(choices.count == 1 ? "title" : "titles") found · review the episode order"
                if identificationCompleted { step = .episodes } else { beginIdentification() }
            } catch is CancellationError { choices = []; detail = "Scan canceled" }
            catch { self.error = error.localizedDescription; detail = "Couldn't scan this source" }
        }
    }
    private func accept(_ titles: [DiscTitle]) {
        var episode = firstEpisode
        choices = titles.sorted { $0.index < $1.index }.map { title in
            let selected = (20 * 60...100 * 60).contains(title.duration)
            let result = EpisodeChoice(title: title, selected: selected, episode: episode)
            if selected { episode += 1 }
            return result
        }
    }
    func renumber() {
        var number = firstEpisode
        for index in choices.indices where choices[index].selected { choices[index].episode = number; number += 1 }
    }
    func cancel() { stopped = true; engine.cancel() }
    private var subtitleOmissionSnapshot: [String] {
        choices.filter(\.selected).flatMap { item in
            item.title.subtitleTracks.filter { !$0.isText }.map { "\(source?.path ?? "")|\(item.id):\($0.index)" }
        }
    }
    var hasPictureSubtitles: Bool { !subtitleOmissionSnapshot.isEmpty }
    var needsSubtitleDecision: Bool {
        !container.supportsPictureSubtitles && hasPictureSubtitles && approvedSubtitleOmissions != subtitleOmissionSnapshot
    }
    func leaveOutPictureSubtitles() { approvedSubtitleOmissions = subtitleOmissionSnapshot }
    var estimatedExportBytes: Int64 {
        choices.filter(\.selected).reduce(0) { $0 + EncodingPlan.estimatedBytes(title: $1.title, profile: profile, encoder: encoder, filter: filter) }
    }
    func estimatedSize(for title: DiscTitle) -> String {
        ByteCountFormatter.string(fromByteCount: EncodingPlan.estimatedBytes(title: title, profile: profile, encoder: encoder, filter: filter), countStyle: .file)
    }
    func export() {
        guard canExport, let source, let destination else { return }
        let selected = choices.filter(\.selected)
        guard Set(selected.map(\.episode)).count == selected.count else {
            error = "Two selected titles have the same episode number. Give each episode a unique number."; return
        }
        jobs = selected.map { item in
            ExportJob(title: item.id, episode: item.episode, source: source,
                      output: destination.appendingPathComponent(MediaNaming.relativePath(series: series, year: year, season: season, episode: item.episode, container: container)),
                      profile: profile, filter: filter, encoder: encoder, container: container, subtitles: item.title.subtitleTracks, width: item.title.width, height: item.title.height)
        }
        busy = true; stopped = false; error = nil; step = .exporting
        let selectedExecutable = executable, selectedLibrary = libraryDirectory
        let shouldEject = ejectAfter
        preventSleep = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Exporting DVD episodes")
        operationTask = Task { [self] in
            defer {
                busy = false
                if let token = preventSleep { ProcessInfo.processInfo.endActivity(token); preventSleep = nil }
            }
            do {
                detail = "Checking hardware encoder…"
                var help = ""
                try await engine.run(executable: selectedExecutable, arguments: ["--help"], libraryDirectory: selectedLibrary,
                                     event: { _ in }, log: { help = String((help + $0).suffix(100_000)) },
                                     captureOutput: { help = String((help + $0).suffix(100_000)) })
                if stopped { throw CancellationError() }
                guard let first = jobs.first, HardwareEncoderEvidence.advertises(first.encoder, help: help) else {
                    throw EngineFailure(message: "This HandBrakeCLI does not offer the selected Mac hardware encoder. Update HandBrakeCLI or choose the other format. DiscShift won’t switch to a CPU encoder.")
                }
            } catch {
                for i in jobs.indices { jobs[i].status = stopped || i > 0 ? "Canceled" : "Failed" }
                if !stopped { self.error = error.localizedDescription }
                detail = "Export could not start"
                return
            }
            for index in jobs.indices {
                if stopped { jobs[index].status = "Canceled"; continue }
                let job = jobs[index]
                let folder = job.output.deletingLastPathComponent()
                // Keep incomplete files out of the Jellyfin season folder.
                let temporaryFolder = destination.appendingPathComponent(".discshift-staging", isDirectory: true)
                let temporary = temporaryFolder.appendingPathComponent("\(UUID().uuidString).\(job.container.fileExtension)")
                do {
                    guard !FileManager.default.fileExists(atPath: job.output.path) else {
                        throw EngineFailure(message: "An episode already exists: \(job.output.lastPathComponent). Nothing was overwritten.")
                    }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
                    jobs[index].status = "Encoding"; detail = "Exporting episode \(job.episode)"
                    var encoderLog = ""
                    try await engine.run(executable: selectedExecutable,
                        arguments: EncodeCommand.arguments(source: job.source.path, title: job.title, output: temporary.path, profile: job.profile, filter: job.filter, encoder: job.encoder, width: job.width, height: job.height, container: job.container, subtitles: job.subtitles),
                        libraryDirectory: selectedLibrary, event: { [weak self] event in
                            if case .progress(let value, let eta) = event {
                                self?.jobs[index].progress = value; self?.detail = eta
                            }
                        }, log: { [weak self] chunk in
                            self?.appendLog(chunk)
                            if self?.jobs[index].hardwareEncoderID == nil {
                                let combined = encoderLog + chunk
                                if let identifier = HardwareEncoderEvidence.identifier(in: combined, for: job.encoder) {
                                    self?.jobs[index].hardwareEncoderID = identifier
                                }
                                encoderLog = String(combined.suffix(512))
                            }
                        })
                    if stopped { throw CancellationError() }
                    guard jobs[index].hardwareEncoderID != nil else {
                        throw EngineFailure(message: "HandBrake did not confirm a hardware video encoder. The incomplete output was discarded. Open Activity for details or update HandBrakeCLI.")
                    }
                    let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0 else { throw EngineFailure(message: "HandBrake produced an empty file.") }
                    // moveItem refuses an existing destination, including files created during the encode.
                    try FileManager.default.moveItem(at: temporary, to: job.output)
                    jobs[index].outputBytes = Int64(size)
                    jobs[index].status = "Complete"; jobs[index].progress = 1
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    jobs[index].status = stopped ? "Canceled" : "Failed"
                    if !stopped { self.error = error.localizedDescription }
                    stopped = true
                }
            }
            let success = jobs.allSatisfy { $0.status == "Complete" }
            detail = success ? "All episodes are ready for Jellyfin" : "Export stopped · completed episodes are saved"
            if success && shouldEject {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: source) }
                catch { self.error = "Episodes saved, but the source could not be ejected: \(error.localizedDescription)" }
            }
        }
    }
}

extension AppModel {
    var matchingShow: CatalogShow? {
        guard let show = identifiedShow,
              show.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(series.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame,
              show.year == year.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return show
    }
    var currentCatalog: [CatalogEpisode] {
        guard matchingShow != nil else { return [] }
        return catalogEpisodes.filter { $0.season == season && ($0.number ?? 0) > 0 }
            .sorted { ($0.number ?? 0) < ($1.number ?? 0) }
    }
    var availableSeasons: [Int] { matchingShow == nil ? [] : Array(Set(catalogEpisodes.filter { ($0.number ?? 0) > 0 }.map(\.season))).sorted() }
    func episodeMetadata(_ episode: Int) -> CatalogEpisode? { currentCatalog.first { $0.number == episode } }
    private var orderSnapshot: OrderSnapshot {
        OrderSnapshot(source: source?.path, series: series, year: year, season: season,
                      showID: currentCatalog.isEmpty ? nil : identifiedShow?.id,
                      assignments: choices.filter(\.selected).map { .init(title: $0.id, episode: $0.episode, catalogID: episodeMetadata($0.episode)?.id) })
    }
    var episodeOrderConfirmed: Bool {
        get { selectedCount > 0 && confirmedOrder == orderSnapshot }
        set { confirmedOrder = newValue ? orderSnapshot : nil }
    }
    private func stopMetadataLookup() {
        metadataRevision = UUID(); metadataTask?.cancel(); lookingUpShow = false
    }
    private func resetIdentification(preservingShow: Bool) {
        stopMetadataLookup(); confirmedOrder = nil
        if !preservingShow {
            searchQuery = ""; showMatches = []; identifiedShow = nil; catalogEpisodes = []
            metadataMessage = nil; identificationCompleted = false; manualEpisodeNumbers = false; enteringShowManually = false
        }
    }
    private func beginIdentification() {
        step = .identify
        let base = source?.lastPathComponent.uppercased() == "VIDEO_TS" ? source?.deletingLastPathComponent() : source
        searchQuery = base.map { DiscLabelHint.query($0.deletingPathExtension().lastPathComponent, words: DiscLabelHint.systemWords) } ?? ""
        if automaticShowLookup && !searchQuery.isEmpty { searchShows() }
        else { metadataMessage = "Search for the show, or enter the details manually." }
    }
    func searchShows() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        enteringShowManually = false
        stopMetadataLookup()
        if identifiedShow != nil { series = ""; year = "" }
        identifiedShow = nil; catalogEpisodes = []; showMatches = []; confirmedOrder = nil
        identificationCompleted = false; metadataMessage = nil; lookingUpShow = true
        let revision = metadataRevision
        metadataTask = Task { [self] in
            defer { if metadataRevision == revision { lookingUpShow = false } }
            do {
                let matches = try await metadataProvider.search(query: query)
                guard metadataRevision == revision, !Task.isCancelled else { return }
                showMatches = Array(matches.prefix(20))
                metadataMessage = matches.isEmpty ? "No matching shows found. Try a shorter name or enter details manually." : "Choose the correct show and year. Similar names may refer to different versions."
                if matches.count == 1 { selectShow(matches[0]) }
            } catch {
                guard metadataRevision == revision, !Task.isCancelled else { return }
                metadataMessage = "Couldn’t look up shows: \(error.localizedDescription) You can enter details manually."
            }
        }
    }
    func selectShow(_ show: CatalogShow) {
        guard identifiedShow?.id != show.id else { return }
        enteringShowManually = false
        stopMetadataLookup()
        identifiedShow = show; series = show.name; year = show.year
        catalogEpisodes = []; confirmedOrder = nil; identificationCompleted = false
        manualEpisodeNumbers = false; lookingUpShow = true
        metadataMessage = "Loading episode names…"
        let revision = metadataRevision
        metadataTask = Task { [self] in
            defer { if metadataRevision == revision { lookingUpShow = false } }
            do {
                let episodes = try await metadataProvider.episodes(showID: show.id)
                guard metadataRevision == revision, !Task.isCancelled else { return }
                catalogEpisodes = episodes
                if !availableSeasons.contains(season), let first = availableSeasons.first { season = first }
                metadataMessage = episodes.isEmpty ? "Show details found. Episode names aren’t available; you can number titles manually." : "Show details and episode names are ready. You’ll confirm the season and order next."
            } catch {
                guard metadataRevision == revision, !Task.isCancelled else { return }
                metadataMessage = "Show details found, but episode names couldn’t be loaded. You can number titles manually."
            }
        }
    }
    func enterShowManually() {
        let name = series, releaseYear = year
        resetIdentification(preservingShow: false)
        series = name; year = releaseYear
        enteringShowManually = true; step = .identify
    }
    func returnToShowSearch() {
        enteringShowManually = false
        if searchQuery.isEmpty { searchQuery = series }
        if !searchQuery.isEmpty { searchShows() }
    }
}
