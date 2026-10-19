import SwiftUI
import AppKit

@main @MainActor struct DiscShiftApp: App {
    @StateObject private var model = AppModel(defaults: SettingsStore.standard())
    @StateObject private var updates = AppUpdates()
    @StateObject private var installation = AppInstallation()
    @NSApplicationDelegateAdaptor(DiscShiftDelegate.self) private var appDelegate
    var body: some Scene {
        Window("DiscShift", id: "main") {
            Group {
                if installation.isReady {
                    ContentView().environmentObject(model).environmentObject(updates)
                        .onAppear { appDelegate.model = model; updates.attach(to: model, hostBundle: installation.hostBundle) }
                } else { AppInstallationView(installation: installation) }
            }
            .frame(minWidth: 800, minHeight: 640)
            .task { await installation.prepare() }
        }
        .defaultSize(width: 920, height: 740)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updates.check)
                    .disabled(!installation.isReady || !updates.canCheck || updates.operationInProgress)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Source…") { model.chooseSource() }.keyboardShortcut("o").disabled(!installation.isReady || model.busy || model.showingSetup)
            }
            CommandMenu("Disc") {
                Button("Find Mounted DVD") { model.discoverDisc() }.disabled(!installation.isReady || model.busy || model.showingSetup)
                Divider()
                Button("Scan Source") { model.scan() }.keyboardShortcut("r").disabled(!installation.isReady || model.source == nil || model.busy || model.showingSetup)
                Button("Export Episodes") { model.export() }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(!installation.isReady || model.step != .review || !model.canExport || model.showingSetup)
                Button("Cancel Operation") { model.cancel() }.disabled(!installation.isReady || !model.busy)
                Divider()
                Button("Show Activity") { model.showingActivity = true }.keyboardShortcut("l", modifiers: [.command, .option]).disabled(!installation.isReady)
            }
            CommandGroup(replacing: .help) {
                Button("Set Up DiscShift…") { model.openSetup() }.disabled(!installation.isReady || model.busy)
                Link("DiscShift Help", destination: URL(string: "https://github.com/iOSDeveloperGuy/DiscShift#readme")!)
            }
        }
        Settings {
            if installation.isReady { ReaderSettingsView().environmentObject(model).environmentObject(updates) }
            else { AppInstallationView(installation: installation) }
        }
    }
}

@MainActor final class DiscShiftDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model, model.updateInstallationPending && (model.busy || model.setup.isWorking) {
            return .terminateCancel
        }
        if let model, model.setup.isWorking {
            model.setup.cancel()
            Task {
                await model.setup.task?.value
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        guard let model, model.busy else { return .terminateNow }
        model.cancel()
        Task {
            await model.operationTask?.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
