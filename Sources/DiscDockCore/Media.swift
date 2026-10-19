import Foundation

public struct SubtitleTrack: Equatable {
    public let index: Int
    public let isText: Bool
    public init(index: Int, isText: Bool) { self.index = index; self.isText = isText }
}
public struct DiscTitle: Identifiable, Decodable, Equatable {
    public var id: Int { index }
    public let index: Int
    public let duration: Int
    public let chapters: Int
    public let width: Int
    public let height: Int
    public let audioBitrate: Int?
    public let audioTrackCount: Int
    public let subtitleTracks: [SubtitleTrack]
    public init(index: Int, duration: Int, chapters: Int, width: Int = 720, height: Int = 480, audioBitrate: Int? = nil, audioTrackCount: Int = 1, subtitleTracks: [SubtitleTrack] = []) {
        self.index = index; self.duration = duration; self.chapters = chapters
        self.width = width; self.height = height
        self.audioBitrate = audioBitrate; self.audioTrackCount = audioTrackCount
        self.subtitleTracks = subtitleTracks
    }
    public var time: String { String(format: "%d:%02d", duration / 60, duration % 60) }
    enum CodingKeys: String, CodingKey { case index = "Index", duration = "Duration", chapters = "ChapterList", geometry = "Geometry", audio = "AudioList", subtitles = "SubtitleList" }
    private struct Duration: Decodable { let Hours: Int; let Minutes: Int; let Seconds: Int }
    private struct Geometry: Decodable { let Width: Int; let Height: Int }
    private struct Chapter: Decodable {}
    private struct Audio: Decodable { let BitRate: Int? }
    private struct Subtitle: Decodable { let Format: String? }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        let d = try c.decode(Duration.self, forKey: .duration)
        duration = d.Hours * 3600 + d.Minutes * 60 + d.Seconds
        chapters = (try? c.decode([Chapter].self, forKey: .chapters).count) ?? 0
        let g = try c.decode(Geometry.self, forKey: .geometry)
        width = g.Width; height = g.Height
        let audio = try? c.decode([Audio].self, forKey: .audio)
        audioTrackCount = audio?.count ?? 1
        audioBitrate = audio.flatMap { tracks in
            tracks.allSatisfy { ($0.BitRate ?? 0) > 0 } ? tracks.reduce(0) { $0 + ($1.BitRate ?? 0) } : nil
        }
        let subtitles = (try? c.decode([Subtitle].self, forKey: .subtitles)) ?? []
        subtitleTracks = subtitles.enumerated().map { SubtitleTrack(index: $0.offset + 1, isText: $0.element.Format?.lowercased() == "text") }
    }
}

/// HandBrake emits labeled, multiline JSON mixed with diagnostic text.
/// Frame balanced JSON objects rather than assuming stdout is one JSON document.
public struct JSONFrames {
    private var buffer = Data()
    private var depth = 0
    private var inString = false
    private var escaped = false
    public init() {}
    public mutating func append(_ data: Data) -> [Data] {
        var frames: [Data] = []
        for byte in data {
            if depth == 0 {
                guard byte == 123 else { continue }
                buffer = Data([byte]); depth = 1; inString = false; escaped = false
                continue
            }
            buffer.append(byte)
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 {
                depth -= 1
                if depth == 0 { frames.append(buffer); buffer.removeAll(keepingCapacity: true) }
            }
            // Bound malformed diagnostics, keeping the app responsive.
            if buffer.count > 16_000_000 { buffer.removeAll(); depth = 0 }
        }
        return frames
    }
}

public enum HandBrakeEvent {
    case titles([DiscTitle])
    case scanning(Double, String)
    case progress(Double, String)
    public static func decode(_ data: Data) -> HandBrakeEvent? {
        struct Titles: Decodable { let TitleList: [DiscTitle] }
        if let t = try? JSONDecoder().decode(Titles.self, from: data) { return .titles(t.TitleList) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = object["State"] as? String else { return nil }
        if state == "SCANNING", let scan = object["Scanning"] as? [String: Any] {
            let title = scan["Title"] as? Int ?? 0
            let count = scan["TitleCount"] as? Int ?? 0
            return .scanning(scan["Progress"] as? Double ?? 0, count > 0 ? "Reading title \(title) of \(count)…" : "Reading titles and chapters…")
        }
        if state == "SEARCHING" { return .progress(0, "Finding the starting point") }
        if let working = object["Working"] as? [String: Any], let p = working["Progress"] as? Double {
            let seconds = (working["ETASeconds"] as? Int) ?? -1
            let eta = seconds >= 0 ? "About \(max(1, seconds / 60)) min remaining" : "Encoding video"
            return .progress(min(0.98, max(0, p) * 0.98), eta)
        }
        if state == "MUXING" { return .progress(0.99, "Finishing container") }
        return nil
    }
}

public enum VideoProfile: String, CaseIterable, Identifiable {
    case compact = "Smaller files", balanced = "Beautiful & compact", quality = "Maximum detail"
    public var id: String { rawValue }
    public var title: String {
        switch self { case .compact: return "Smaller files"; case .balanced: return "Balanced"; case .quality: return "Higher quality" }
    }
    public var hevcBitrate: Int {
        switch self { case .compact: return 700; case .balanced: return 1000; case .quality: return 1800 }
    }
}
public enum VideoEncoder: String, CaseIterable, Identifiable {
    case hevc, h264
    public var id: String { rawValue }
    public var title: String { self == .hevc ? "HEVC · Smaller files" : "H.264 · Compatibility" }
    public var codec: String { self == .hevc ? "HEVC" : "H.264" }
    public var handBrakeName: String { self == .hevc ? "vt_h265" : "vt_h264" }
}
public enum ExportContainer: String, CaseIterable, Identifiable {
    case mp4, m4v, mov, mkv
    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }
    public var handBrakeName: String {
        switch self { case .mp4, .m4v: return "av_mp4"; case .mov: return "av_mov"; case .mkv: return "av_mkv" }
    }
    public var supportsPictureSubtitles: Bool { self == .mkv }
    public var detail: String {
        switch self {
        case .mp4: return "A good choice for sharing and playback on most devices."
        case .m4v: return "The same container as MP4, using Apple’s video file extension."
        case .mov: return "A QuickTime movie. Uses the same compact hardware video settings."
        case .mkv: return "Keeps picture subtitles and the widest range of original audio tracks."
        }
    }
}
public enum EncodingPlan {
    public static func videoBitrate(profile: VideoProfile, encoder: VideoEncoder, width: Int = 720, height: Int = 480, filter: MotionFilter = .adaptive) -> Int {
        // Keep NTSC and PAL DVDs at the same target. Larger sources and bob's
        // doubled motion rate receive more bits rather than a DVD-only budget.
        let pixels = Double(max(1, width)) * Double(max(1, height))
        let scale = pow(max(1, pixels / (720 * 576)), 0.65)
        let codecScale = encoder == .hevc ? 1.0 : 1.8
        let motionScale = filter == .bob ? 1.5 : 1.0
        return Int((Double(profile.hevcBitrate) * scale * codecScale * motionScale / 50).rounded()) * 50
    }
    public static func estimatedBytes(title: DiscTitle, profile: VideoProfile, encoder: VideoEncoder, filter: MotionFilter) -> Int64 {
        let video = videoBitrate(profile: profile, encoder: encoder, width: title.width, height: title.height, filter: filter) * 1000
        let audio = title.audioBitrate ?? (256_000 * title.audioTrackCount)
        return Int64(Double(video + audio) * Double(max(0, title.duration)) / 8 * 1.02)
    }
}
public enum HardwareEncoderEvidence {
    public static func identifier(in log: String, for encoder: VideoEncoder? = nil) -> String? {
        let pattern = #"encvt_Init:\s+(com\.apple\.videotoolbox\.videoencoder\.[A-Za-z0-9._-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: log, range: NSRange(log.startIndex..., in: log)) {
            guard let range = Range(match.range(at: 1), in: log) else { continue }
            let id = String(log[range])
            if encoder == nil || (encoder == .hevc && id.contains("hevc")) ||
                (encoder == .h264 && (id.contains("h264") || id.contains("avc"))) { return id }
        }
        return nil
    }
    public static func advertises(_ encoder: VideoEncoder, help: String) -> Bool {
        help.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == encoder.handBrakeName }
    }
}
public enum MotionFilter: String, CaseIterable, Identifiable {
    case adaptive = "Adaptive decomb", bob = "Smooth motion (bob)", off = "Off"
    public var id: String { rawValue }
}
public enum MediaNaming {
    public static func clean(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\0\n\r").union(.controlCharacters)
        let result = value.components(separatedBy: forbidden).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return result.isEmpty ? "Untitled" : result
    }
    public static func relativePath(series: String, year: String, season: Int, episode: Int, container: ExportContainer = .mp4) -> String {
        let name = clean(series)
        let digits = year.filter(\.isNumber)
        let folder = digits.count == 4 ? "\(name) (\(digits))" : name
        return String(format: "%@/Season %02d/%@ S%02dE%02d.%@", folder, season, name, season, episode, container.fileExtension)
    }
}
public enum EncodeCommand {
    public static func arguments(source: String, title: Int, output: String, profile: VideoProfile,
                                 filter: MotionFilter, encoder: VideoEncoder = .hevc, width: Int = 720, height: Int = 480,
                                 container: ExportContainer = .mp4, subtitles: [SubtitleTrack] = []) -> [String] {
        var args = ["--json", "-i", source, "-t", String(title), "-o", output,
                    "-f", container.handBrakeName, "-e", encoder.handBrakeName,
                    "-b", String(EncodingPlan.videoBitrate(profile: profile, encoder: encoder, width: width, height: height, filter: filter)),
                    "--encoder-preset", "quality", "--enable-hw-decoding", "videotoolbox",
                    "--vfr", "--crop", "0:0:0:0", "--auto-anamorphic", "--all-audio",
                    "--aencoder", "copy", "--audio-fallback", "ca_aac", "--markers", "--subtitle-burned=none"]
        if container == .mkv {
            args += ["--all-subtitles"]
        } else {
            let textTracks = subtitles.filter(\.isText).map { String($0.index) }.joined(separator: ",")
            args += ["--audio-copy-mask", "aac,ac3,eac3,mp3,alac",
                     "--subtitle", textTracks.isEmpty ? "none" : textTracks]
            if container != .mov { args += ["--optimize"] }
        }
        switch filter {
        case .adaptive: args += ["--comb-detect", "--decomb"]
        case .bob: args += ["--decomb=bob", "--no-comb-detect"]
        case .off: args += ["--no-comb-detect", "--no-decomb", "--no-deinterlace"]
        }
        return args
    }
}
