import XCTest
@testable import DiscShiftCore

final class MediaTests: XCTestCase {
    func testScanAcrossEveryPossibleChunkBoundary() throws {
        let fixture = #"JSON Title Set: {"TitleList":[{"Index":2,"Name":"A } brace and \"quote\" café","Duration":{"Hours":0,"Minutes":50,"Seconds":21},"Geometry":{"Width":720,"Height":576},"ChapterList":[{},{}]}]}"#
        let bytes = Data(fixture.utf8)
        for boundary in 0...bytes.count {
            var parser = JSONFrames()
            let frames = parser.append(Data(bytes.prefix(boundary))) + parser.append(Data(bytes.dropFirst(boundary)))
            XCTAssertEqual(frames.count, 1)
            guard let first = frames.first, case .titles(let titles) = HandBrakeEvent.decode(first) else {
                XCTFail("Could not decode at split \(boundary)"); continue
            }
            XCTAssertEqual(titles.count, 1)
            XCTAssertEqual(titles[0].id, 2)
            XCTAssertEqual(titles[0].duration, 3021)
            XCTAssertEqual(titles[0].height, 576)
            XCTAssertEqual(titles[0].chapters, 2)
        }
    }
    func testAdjacentProgressAndDiagnostics() {
        var parser = JSONFrames()
        let frames = parser.append(Data(#"HandBrake 1.11 Progress: {"State":"WORKING","Working":{"Progress":0.25,"ETASeconds":120}} Progress: {"State":"MUXING"}"#.utf8))
        XCTAssertEqual(frames.count, 2)
        guard case .progress(let fraction, _) = HandBrakeEvent.decode(frames[0]) else { return XCTFail("No progress") }
        XCTAssertEqual(fraction, 0.245, accuracy: 0.0001)
        XCTAssertNil(HandBrakeEvent.decode(Data("not json".utf8)))
    }
    func testScanProgressNamesTheCurrentTitle() {
        let data = Data(#"{"State":"SCANNING","Scanning":{"Progress":0.25,"Title":2,"TitleCount":4}}"#.utf8)
        guard case .scanning(let fraction, let label) = HandBrakeEvent.decode(data) else { return XCTFail("Missing scan state") }
        XCTAssertEqual(fraction, 0.25); XCTAssertEqual(label, "Reading title 2 of 4…")
    }
    func testSeekingDoesNotReportEncodingCompletion() {
        let data = Data(#"{"State":"SEARCHING","Working":{"Progress":0.9}}"#.utf8)
        guard case .progress(let fraction, let label) = HandBrakeEvent.decode(data) else { return XCTFail("Missing search state") }
        XCTAssertEqual(fraction, 0); XCTAssertTrue(label.contains("starting"))
    }
    func testNamesCannotEscapeLibrary() {
        let path = MediaNaming.relativePath(series: "../../A/B:\nShow", year: "1978", season: 1, episode: 3)
        XCTAssertFalse(path.contains("../"))
        XCTAssertEqual(path.split(separator: "/").count, 3)
        XCTAssertTrue(path.hasSuffix("S01E03.mp4"))
        XCTAssertEqual(MediaNaming.clean("..."), "Untitled")
    }
    func testSourcePathIsOneArgumentAndTimingIsNotForced() {
        let source = "/Volumes/A DVD; $(touch surprise)"
        let args = EncodeCommand.arguments(source: source, title: 2, output: "/tmp/episode.mkv", profile: .balanced, filter: .adaptive, container: .mkv)
        XCTAssertEqual(args[2], source)
        XCTAssertEqual(args[args.firstIndex(of: "-e")! + 1], "vt_h265")
        XCTAssertFalse(args.contains("-q"))
        XCTAssertFalse(args.contains("--rate"))
        XCTAssertTrue(args.contains("--comb-detect"))
        XCTAssertTrue(args.contains("--all-subtitles"))
        XCTAssertEqual(args[args.firstIndex(of: "--audio-fallback")! + 1], "ca_aac")
        let bob = EncodeCommand.arguments(source: source, title: 1, output: "/tmp/a.mkv", profile: .quality, filter: .bob)
        XCTAssertTrue(bob.contains("--decomb=bob"))
        XCTAssertTrue(bob.contains("--no-comb-detect"))
    }
    func testHardwareProfilesHavePredictableBitrateAndEstimates() throws {
        let title = DiscTitle(index: 1, duration: 3000, chapters: 10, audioBitrate: 192_000)
        let compact = EncodingPlan.estimatedBytes(title: title, profile: .compact, encoder: .hevc, filter: .adaptive)
        let balanced = EncodingPlan.estimatedBytes(title: title, profile: .balanced, encoder: .hevc, filter: .adaptive)
        let quality = EncodingPlan.estimatedBytes(title: title, profile: .quality, encoder: .hevc, filter: .adaptive)
        XCTAssertLessThan(compact, balanced); XCTAssertLessThan(balanced, quality)
        XCTAssertEqual(balanced, 455_940_000)
        XCTAssertGreaterThan(EncodingPlan.estimatedBytes(title: title, profile: .balanced, encoder: .h264, filter: .adaptive), balanced)
        XCTAssertGreaterThan(EncodingPlan.videoBitrate(profile: .balanced, encoder: .hevc, width: 1920, height: 1080), 1000)
        XCTAssertGreaterThan(EncodingPlan.videoBitrate(profile: .balanced, encoder: .hevc, filter: .bob), 1000)
        for encoder in VideoEncoder.allCases {
            let args = EncodeCommand.arguments(source: "/input", title: 1, output: "/output", profile: .compact, filter: .off, encoder: encoder)
            XCTAssertEqual(args[args.firstIndex(of: "-e")! + 1], encoder.handBrakeName)
            XCTAssertEqual(args[args.firstIndex(of: "--encoder-preset")! + 1], "quality")
            XCTAssertTrue(args.contains("--enable-hw-decoding"))
        }
    }
    func testScanAccountsForEveryAudioTrackInSizeEstimate() throws {
        let json = #"{"Index":1,"Duration":{"Hours":0,"Minutes":1,"Seconds":0},"Geometry":{"Width":720,"Height":480},"ChapterList":[],"AudioList":[{"BitRate":192000},{"BitRate":448000}]}"#
        let title = try JSONDecoder().decode(DiscTitle.self, from: Data(json.utf8))
        XCTAssertEqual(title.audioTrackCount, 2); XCTAssertEqual(title.audioBitrate, 640_000)
        let unknown = DiscTitle(index: 1, duration: 60, chapters: 0, audioTrackCount: 2)
        XCTAssertGreaterThan(EncodingPlan.estimatedBytes(title: title, profile: .balanced, encoder: .hevc, filter: .adaptive),
                             EncodingPlan.estimatedBytes(title: unknown, profile: .balanced, encoder: .hevc, filter: .adaptive))
    }
    func testHardwareEvidenceRequiresMatchingRealEncoderIdentifier() {
        let hevc = "[12:00] encvt_Init: com.apple.videotoolbox.videoencoder.ave.hevc"
        XCTAssertNotNil(HardwareEncoderEvidence.identifier(in: hevc, for: .hevc))
        XCTAssertNil(HardwareEncoderEvidence.identifier(in: hevc, for: .h264))
        XCTAssertNotNil(HardwareEncoderEvidence.identifier(in: "encvt_Init: com.apple.videotoolbox.videoencoder.ave.avc", for: .h264))
        XCTAssertNil(HardwareEncoderEvidence.identifier(in: "encoder: H.265 (VideoToolbox)\nx264: using cpu"))
        XCTAssertTrue(HardwareEncoderEvidence.advertises(.hevc, help: "-e encoder\n    vt_h265\n    vt_h264\n"))
        XCTAssertFalse(HardwareEncoderEvidence.advertises(.hevc, help: "vt_h265_10bit\n"))
    }
    func testContainerChoicesUseRealMuxersAndCorrectExtensions() {
        let tracks = [SubtitleTrack(index: 1, isText: false), SubtitleTrack(index: 2, isText: true)]
        for container in ExportContainer.allCases {
            let path = MediaNaming.relativePath(series: "A/B", year: "1978", season: 1, episode: 2, container: container)
            XCTAssertTrue(path.hasSuffix("S01E02." + container.fileExtension))
            let args = EncodeCommand.arguments(source: "/source", title: 1, output: path, profile: .balanced, filter: .adaptive, container: container, subtitles: tracks)
            XCTAssertEqual(args[args.firstIndex(of: "-f")! + 1], container.handBrakeName)
            XCTAssertEqual(args[args.firstIndex(of: "-e")! + 1], "vt_h265")
            XCTAssertTrue(args.contains("--subtitle-burned=none"))
            if container == .mkv {
                XCTAssertTrue(args.contains("--all-subtitles")); XCTAssertFalse(args.contains("--audio-copy-mask"))
            } else {
                XCTAssertEqual(args[args.firstIndex(of: "--subtitle")! + 1], "2")
                XCTAssertTrue(args.contains("--audio-copy-mask"))
            }
            XCTAssertEqual(args.contains("--optimize"), container == .mp4 || container == .m4v)
        }
    }
    func testScanDistinguishesTextAndPictureSubtitles() throws {
        let json = #"{"Index":1,"Duration":{"Hours":0,"Minutes":1,"Seconds":0},"Geometry":{"Width":720,"Height":480},"ChapterList":[],"SubtitleList":[{"Format":"bitmap"},{"Format":"text"},{}]}"#
        let title = try JSONDecoder().decode(DiscTitle.self, from: Data(json.utf8))
        XCTAssertEqual(title.subtitleTracks, [SubtitleTrack(index: 1, isText: false), SubtitleTrack(index: 2, isText: true), SubtitleTrack(index: 3, isText: false)])
    }
}
