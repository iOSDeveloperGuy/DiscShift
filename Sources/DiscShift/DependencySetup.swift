import AppKit
import SwiftUI
import DiscShiftCore

enum ReaderLocations {
    static let readers = ["/opt/homebrew/bin/HandBrakeCLI", "/usr/local/bin/HandBrakeCLI", "/opt/local/bin/HandBrakeCLI"]
    static let libraries = ["/opt/homebrew/lib", "/usr/local/lib", "/opt/local/lib"]
    static var brew: String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    static func reader(preferred: String) -> String? {
        ([preferred] + readers).first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func dvdLibrary(preferred: String) -> String? {
        ([preferred] + libraries).first { folder in
            ["libdvdcss.2.dylib", "libdvdcss.dylib"].contains { FileManager.default.fileExists(atPath: folder + "/" + $0) }
        }
    }
}

/// Setup never reads a disc. A successful check establishes reader/version and
/// advertised encoders; actual hardware use remains verified during every export.
@MainActor final class DependencySetup: ObservableObject {
    @Published var readerPath: String
    @Published var libraryPath: String
    @Published private(set) var version: String?
    @Published private(set) var supportsHEVC = false
    @Published private(set) var supportsH264 = false
    @Published private(set) var isWorking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var message: String?
    @Published private(set) var diagnostics = ""
    private var verifiedReader: String?
    private var verifiedLibrary: String?
    private let engine = HandBrakeEngine()
    private(set) var task: Task<Void, Never>?
    private var canceled = false
    var isReady: Bool { verifiedReader == readerPath && verifiedLibrary == libraryPath && version != nil && (supportsHEVC || supportsH264) && !isWorking }
    var dvdLibraryFound: Bool { ReaderLocations.dvdLibrary(preferred: libraryPath) == libraryPath }

    init(readerPath: String, libraryPath: String) {
        self.readerPath = readerPath; self.libraryPath = libraryPath
    }
    private func append(_ text: String) { diagnostics = String((diagnostics + text).suffix(40_000)) }
    func cancel() { canceled = true; engine.cancel() }
    func check() {
        guard !isWorking else { return }
        isWorking = true; canceled = false; message = nil; diagnostics = ""
        verifiedReader = nil; version = nil; supportsHEVC = false; supportsH264 = false
        if let found = ReaderLocations.reader(preferred: readerPath) { readerPath = found }
        if let found = ReaderLocations.dvdLibrary(preferred: libraryPath) { libraryPath = found }
        let reader = readerPath, library = libraryPath
        task = Task {
            defer { isWorking = false }
            do {
                try await verify(reader: reader, library: library)
            } catch is CancellationError { message = "Check canceled. You can try again whenever you’re ready." }
            catch { message = "Your reader isn’t ready yet. Try installing it, or choose another copy in Advanced." }
        }
    }
    private func verify(reader: String, library: String) async throws {
        var output = ""
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled { engine.cancel() }
        }
        defer { timeout.cancel() }
        try await engine.run(executable: reader, arguments: ["--version"], libraryDirectory: library, event: { _ in }, log: { self.append($0); output += $0 }, captureOutput: { output += $0 })
        guard !canceled else { throw CancellationError() }
        guard let range = output.range(of: #"HandBrake\s+\d+[^\r\n]*"#, options: .regularExpression) else {
            throw EngineFailure(message: "Not a recognized HandBrakeCLI version.")
        }
        let foundVersion = String(output[range])
        output = ""
        try await engine.run(executable: reader, arguments: ["--help"], libraryDirectory: library, event: { _ in }, log: { self.append($0); output += $0 }, captureOutput: { output += $0 })
        guard !canceled else { throw CancellationError() }
        supportsHEVC = output.contains("vt_h265"); supportsH264 = output.contains("vt_h264")
        guard supportsHEVC || supportsH264 else {
            message = "This reader can’t use your Mac’s hardware encoding. Install a newer reader or choose another copy in Advanced."
            return
        }
        version = foundVersion; verifiedReader = reader; verifiedLibrary = library
    }
    /// Only these two fixed formulae can be installed, with an existing Homebrew.
    /// No shell, privilege escalation, or unattended Homebrew bootstrap is used.
    func install(dvdSupport: Bool = false, brewPath: String? = ReaderLocations.brew) {
        guard !isWorking, let brewPath else { return }
        isWorking = true; isInstalling = true; canceled = false; message = nil; diagnostics = ""
        verifiedReader = nil; version = nil
        task = Task {
            defer { isWorking = false; isInstalling = false }
            do {
                try await engine.run(executable: brewPath, arguments: ["install", dvdSupport ? "libdvdcss" : "handbrake"], libraryDirectory: "", event: { _ in }, log: { self.append($0) }, captureOutput: { self.append($0) }, environmentOverrides: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "NONINTERACTIVE": "1"])
                guard !canceled else { throw CancellationError() }
                let installedReader = URL(fileURLWithPath: brewPath).deletingLastPathComponent().appendingPathComponent("HandBrakeCLI").path
                if FileManager.default.isExecutableFile(atPath: installedReader) { readerPath = installedReader }
                else { readerPath = ReaderLocations.reader(preferred: readerPath) ?? readerPath }
                libraryPath = ReaderLocations.dvdLibrary(preferred: libraryPath) ?? libraryPath
                if dvdSupport && !dvdLibraryFound {
                    message = "Installation finished, but DVD support wasn’t found. Choose its library folder in Advanced, then check again."
                    return
                }
                try await verify(reader: readerPath, library: libraryPath)
            } catch is CancellationError {
                message = "Installation stopped. Anything already installed stays on this Mac. Check again to see what’s ready."
            } catch {
                message = "Installation couldn’t finish. Try again, or open Details below for help. You can also choose a downloaded reader in Advanced."
            }
        }
    }
    func chooseReader() {
        let panel = NSOpenPanel(); panel.message = "Choose HandBrakeCLI from your downloaded or installed command-line package."
        if panel.runModal() == .OK, let url = panel.url { readerPath = url.path; check() }
    }
    func chooseLibrary() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the folder containing libdvdcss."
        if panel.runModal() == .OK, let url = panel.url { libraryPath = url.path; check() }
    }
}
