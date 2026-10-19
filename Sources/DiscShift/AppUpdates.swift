import AppKit
import Combine
import Sparkle
import SwiftUI

/// Holds Sparkle's relaunch callback until scanning, exporting, and setup finish.
@MainActor final class UpdateActivityGate {
    var blocked = true {
        didSet {
            guard !blocked, let handler = pending else { return }
            pending = nil
            handler()
        }
    }
    private var pending: (() -> Void)?
    func cancel() { pending = nil }
    func postpone(_ handler: @escaping () -> Void) -> Bool {
        guard blocked else { return false }
        pending = handler
        return true
    }
}

@MainActor final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var unavailableReason: String?
    @Published private(set) var operationInProgress = true
    private weak var model: AppModel?
    private let gate = UpdateActivityGate()
    private var observation: AnyCancellable?
    private var controller: SPUStandardUpdaterController!
    private var started = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
    }

    func attach(to model: AppModel) {
        guard observation == nil else { return }
        self.model = model
        observation = Publishers.CombineLatest3(model.$busy, model.setup.$isWorking, model.$showingSetup)
            .sink { [weak self] _, _, _ in
                // @Published sends before the model changes. Deliver the relaunch
                // callback after all three stored properties reflect the new state.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.operationInProgress = self.isBusy
                    self.gate.blocked = self.isBusy
                    if !self.gate.blocked { self.startIfNeeded() }
                }
            }
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        do { try controller.updater.start() }
        catch { unavailableReason = error.localizedDescription }
    }
    func check() { controller.checkForUpdates(nil) }
    func setAutomaticChecks(_ value: Bool) { controller.updater.automaticallyChecksForUpdates = value }
    func setAutomaticDownloads(_ value: Bool) { controller.updater.automaticallyDownloadsUpdates = value }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try requireIdle()
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        try requireIdle()
    }
    private func requireIdle() throws {
        if isBusy {
            throw NSError(domain: "com.iosdeveloperguy.discshift.updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Updates will resume when your disc operation or setup finishes."])
        }
    }
    private var isBusy: Bool {
        guard let model else { return true }
        return model.busy || model.setup.isWorking || model.showingSetup
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        // Once installation starts, prevent a new scan/export racing the relaunch.
        model?.updateInstallationPending = true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        gate.cancel()
        model?.updateInstallationPending = false
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        gate.blocked = isBusy
        return gate.postpone(installHandler)
    }
}

struct UpdateSettingsView: View {
    @EnvironmentObject private var updates: AppUpdates
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Section {
            LabeledContent("Version", value: version)
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updates.automaticallyChecks }, set: updates.setAutomaticChecks))
            Toggle("Download updates in the background", isOn: Binding(
                get: { updates.automaticallyDownloads }, set: updates.setAutomaticDownloads))
                .disabled(!updates.automaticallyChecks)
            Button("Check for Updates…", action: updates.check)
                .disabled(!updates.canCheck || updates.operationInProgress)
            if let reason = updates.unavailableReason { Text(reason).foregroundStyle(.secondary) }
        } header: { Text("Updates") } footer: {
            Text("DiscShift checks GitHub for signed updates. Updates wait until scanning, exporting, and setup finish. Downloaded updates can install when you quit.")
        }
    }
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "Development") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
}
