import AppKit
import Security
import SwiftUI

/// File transfer is separate from launch decisions so failed copies can be
/// checked without launching apps or changing a user's Applications folder.
struct AppBundleInstaller {
    static let applicationID = "com.iosdeveloperguy.discshift"

    static func isInstalled(_ app: URL, in directories: [URL]) -> Bool {
        let path = app.resolvingSymlinksInPath().standardizedFileURL.path
        return directories.contains {
            let root = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return path.hasPrefix(root + "/")
        }
    }

    static func info(at app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func validateSignature(_ app: URL, matching source: URL? = nil) throws {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw InstallationError.invalidCopy }
        var requirement: SecRequirement?
        if let source {
            var original: SecStaticCode?
            guard SecStaticCodeCreateWithPath(source as CFURL, [], &original) == errSecSuccess,
                  let original,
                  SecCodeCopyDesignatedRequirement(original, [], &requirement) == errSecSuccess else {
                throw InstallationError.invalidCopy
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw InstallationError.invalidCopy }
    }

    static func isSameSignedCopy(_ lhs: URL, _ rhs: URL) -> Bool {
        guard info(at: lhs)?["CFBundleIdentifier"] as? String == applicationID,
              info(at: rhs)?["CFBundleIdentifier"] as? String == applicationID,
              (try? validateSignature(lhs)) != nil,
              (try? validateSignature(rhs, matching: lhs)) != nil else { return false }
        func codeHash(_ url: URL) -> Data? {
            var code: SecStaticCode?, attributes: CFDictionary?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &attributes) == errSecSuccess,
                  let values = attributes as? [String: Any] else { return nil }
            return values[kSecCodeInfoUnique as String] as? Data
        }
        guard let first = codeHash(lhs), let second = codeHash(rhs) else { return false }
        return first == second
    }

    static func isNewer(_ source: URL, than destination: URL) -> Bool {
        guard let incoming = info(at: source)?["CFBundleVersion"] as? String,
              let installed = info(at: destination)?["CFBundleVersion"] as? String else { return false }
        return incoming.compare(installed, options: .numeric) == .orderedDescending
    }

    /// Never remove the source. Stage and validate the whole app before touching
    /// an existing copy, retaining that copy until placement succeeds.
    static func install(source: URL, destination: URL, replace: Bool = false,
                        validate: (URL) throws -> Void = { try validateSignature($0) },
                        beforePlacement: () throws -> Void = {},
                        place: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> URL? {
        let fm = FileManager.default
        guard info(at: source)?["CFBundleIdentifier"] as? String == applicationID else { throw InstallationError.invalidCopy }
        let existed = fm.fileExists(atPath: destination.path)
        if existed {
            let type = try fm.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
            guard type != .typeSymbolicLink,
                  info(at: destination)?["CFBundleIdentifier"] as? String == applicationID else { throw InstallationError.nameInUse }
            guard replace else { throw InstallationError.alreadyInstalled }
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".DiscShift-Install-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let incoming = staging.appendingPathComponent("DiscShift.app")
        let backup = staging.appendingPathComponent("Previous.app")
        var retainedBackup = false
        defer { if !retainedBackup { try? fm.removeItem(at: staging) } }
        try fm.copyItem(at: source.resolvingSymlinksInPath(), to: incoming)
        try validate(incoming)
        // Recheck the running application immediately before the final rename.
        try beforePlacement()
        if existed {
            try fm.moveItem(at: destination, to: backup)
            retainedBackup = true
        }
        do { try place(incoming, destination) }
        catch {
            if retainedBackup {
                try fm.moveItem(at: backup, to: destination)
                retainedBackup = false
            }
            throw error
        }
        return retainedBackup ? backup : nil
    }

    enum InstallationError: LocalizedError {
        case invalidCopy, alreadyInstalled, nameInUse, runningCopy, reopenFailed, unverifiedInstalledCopy
        var errorDescription: String? {
            switch self {
            case .invalidCopy: return "The app copy could not be verified. Download DiscShift again and try opening the new copy."
            case .unverifiedInstalledCopy: return "The copy in Applications could not be verified. Move it aside in Finder, then try again."
            case .alreadyInstalled: return "DiscShift is already installed in Applications."
            case .nameInUse: return "Applications already contains another item named DiscShift.app. Move it aside in Finder, then try again."
            case .runningCopy: return "The installed copy is running. Finish any exports and quit that copy before replacing it."
            case .reopenFailed: return "DiscShift was installed, but couldn’t reopen. You can open it from Applications."
            }
        }
    }
}

@MainActor final class AppInstallation: ObservableObject {
    @Published private(set) var isReady = false
    private(set) var hostBundle = Bundle.main
    @Published private(set) var error: String?
    private var started = false
    private var installedURL: URL?
    private var backupURL: URL?
    private let source = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL

    func prepare() async {
        guard !started else { return }
        started = true
        let fm = FileManager.default
        let directories = fm.urls(for: .applicationDirectory, in: .allDomainsMask)
        // Package runs, tests, and explicitly marked previews don't install.
        guard Bundle.main.bundleIdentifier == AppBundleInstaller.applicationID,
              Bundle.main.object(forInfoDictionaryKey: "DSInstallOnLaunch") as? Bool == true,
              source.pathExtension == "app", !AppBundleInstaller.isInstalled(source, in: directories) else {
            isReady = true
            return
        }
        // macOS can run an approved download from a read-only translocation
        // even after copying it into Applications. Use the installed bundle only
        // when its complete signature and code identity match this running app.
        // Keep quarantine intact and give Sparkle the physical installed target.
        if source.pathComponents.contains("AppTranslocation") {
            for directory in directories {
                let candidate = directory.appendingPathComponent("DiscShift.app")
                if AppBundleInstaller.isSameSignedCopy(source, candidate), let bundle = Bundle(url: candidate) {
                    hostBundle = bundle
                    isReady = true
                    return
                }
            }
        }
        // Let the installation status draw before the short local copy begins.
        await Task.yield()
        do {
            let systemFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)
            let folder = fm.isWritableFile(atPath: systemFolder.path) ? systemFolder : fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("DiscShift.app")
            var replace = false
            if fm.fileExists(atPath: destination.path) {
                guard AppBundleInstaller.info(at: destination)?["CFBundleIdentifier"] as? String == AppBundleInstaller.applicationID else {
                    throw AppBundleInstaller.InstallationError.nameInUse
                }
                do { try AppBundleInstaller.validateSignature(destination, matching: source) }
                catch { throw AppBundleInstaller.InstallationError.unverifiedInstalledCopy }
                let running = runningCopy(at: destination)
                let canReplace = running == nil && AppBundleInstaller.isNewer(source, than: destination)
                let alert = NSAlert()
                alert.messageText = "DiscShift is already installed"
                if !canReplace {
                    alert.informativeText = running != nil
                        ? "Open the installed copy to continue. To replace it, finish any exports and quit that copy first."
                        : "An up-to-date copy is in Applications. Open it to keep using DiscShift in one place."
                    alert.addButton(withTitle: "Open Installed Copy")
                    alert.addButton(withTitle: "Continue Here")
                } else {
                    let installed = AppBundleInstaller.info(at: destination)?["CFBundleShortVersionString"] as? String ?? ""
                    alert.informativeText = "Version \(installed) is in Applications. You can replace it with this copy or open the installed app."
                    alert.addButton(withTitle: "Replace and Open")
                    alert.addButton(withTitle: "Open Installed Copy")
                    alert.addButton(withTitle: "Continue Here")
                }
                let choice = alert.runModal()
                if !canReplace {
                    if choice == .alertFirstButtonReturn { await reopen(destination, replacing: false) }
                    else { isReady = true }
                    return
                }
                switch choice {
                case .alertFirstButtonReturn: replace = true
                case .alertSecondButtonReturn:
                    await reopen(destination, replacing: false)
                    return
                default:
                    isReady = true
                    return
                }
            }
            backupURL = try AppBundleInstaller.install(source: source, destination: destination, replace: replace,
                validate: { [source] in try AppBundleInstaller.validateSignature($0, matching: source) },
                beforePlacement: { [self] in
                    if runningCopy(at: destination) != nil { throw AppBundleInstaller.InstallationError.runningCopy }
                    if fm.fileExists(atPath: destination.path) {
                        try AppBundleInstaller.validateSignature(destination, matching: source)
                        guard AppBundleInstaller.isNewer(source, than: destination) else { throw AppBundleInstaller.InstallationError.alreadyInstalled }
                    }
                })
            installedURL = destination
            await reopen(destination, replacing: true)
        } catch {
            self.error = (error as? AppBundleInstaller.InstallationError)?.localizedDescription
                ?? "DiscShift couldn’t move into Applications. Check that you have space and can save files there, then try again."
        }
    }

    private func runningCopy(at url: URL) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: AppBundleInstaller.applicationID).first {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
        }
    }

    private func reopen(_ destination: URL, replacing: Bool) async {
        if let existing = runningCopy(at: destination) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            let opened = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
            guard opened.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let openedURL = opened.bundleURL,
                  (openedURL.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL ||
                   AppBundleInstaller.isSameSignedCopy(openedURL, destination)) else {
                throw AppBundleInstaller.InstallationError.reopenFailed
            }
            if let backupURL {
                // The installed app is running successfully; retain the previous
                // copy in Trash rather than deleting it permanently.
                if (try? FileManager.default.trashItem(at: backupURL, resultingItemURL: nil)) != nil {
                    try? FileManager.default.removeItem(at: backupURL.deletingLastPathComponent())
                }
            }
            if replacing { retireDownloadedSource() }
            NSApp.terminate(nil)
        } catch {
            self.error = AppBundleInstaller.InstallationError.reopenFailed.localizedDescription
            installedURL = destination
        }
    }

    private func retireDownloadedSource() {
        let fm = FileManager.default
        // Never delete a project build, a mounted disk's contents, or a
        // translocated original whose actual download path isn't known.
        let folders = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
                       fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")]
        if AppBundleInstaller.isInstalled(source, in: folders) {
            try? fm.trashItem(at: source, resultingItemURL: nil)
        }
    }
    func retry() async {
        error = nil
        if let installedURL { await reopen(installedURL, replacing: false) }
        else { started = false; await prepare() }
    }
    func continueHere() { isReady = true }
    func openApplications() {
        let folder = installedURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/Applications", isDirectory: true)
        NSWorkspace.shared.open(folder)
    }
}

struct AppInstallationView: View {
    @ObservedObject var installation: AppInstallation
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 80, height: 80).accessibilityHidden(true)
            if let error = installation.error {
                Text("Finish installing DiscShift").font(.title).fontWeight(.bold)
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Continue Here", action: installation.continueHere)
                    Button("Open Applications", action: installation.openApplications)
                    Button("Try Again") { Task { await installation.retry() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Installing DiscShift").font(.title).fontWeight(.bold)
                Text("Moving to Applications, then reopening…").foregroundStyle(.secondary)
            }
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
