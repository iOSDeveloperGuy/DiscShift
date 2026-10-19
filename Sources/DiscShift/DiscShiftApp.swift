import SwiftUI
import AppKit

@main @MainActor struct DiscShiftApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(DiscShiftDelegate.self) private var appDelegate
    var body: some Scene {
        Window("DiscShift", id: "main") {
            ContentView().environmentObject(model)
                .frame(minWidth: 800, minHeight: 640)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 920, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Source…") { model.chooseSource() }.keyboardShortcut("o").disabled(model.busy || model.showingSetup)
            }
            CommandMenu("Disc") {
                Button("Find Mounted DVD") { model.discoverDisc() }.disabled(model.busy || model.showingSetup)
                Divider()
                Button("Scan Source") { model.scan() }.keyboardShortcut("r").disabled(model.source == nil || model.busy || model.showingSetup)
                Button("Export Episodes") { model.export() }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.step != .review || !model.canExport || model.showingSetup)
                Button("Cancel Operation") { model.cancel() }.disabled(!model.busy)
                Divider()
                Button("Show Activity") { model.showingActivity = true }.keyboardShortcut("l", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .help) {
                Button("Set Up DiscShift…") { model.openSetup() }.disabled(model.busy)
                Link("DiscShift Help", destination: URL(string: "https://github.com/iOSDeveloperGuy/DiscShift#readme")!)
            }
        }
        Settings {
            ReaderSettingsView().environmentObject(model)
        }
    }
}

@MainActor final class DiscShiftDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
