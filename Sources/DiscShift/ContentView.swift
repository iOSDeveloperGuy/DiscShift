import SwiftUI
import AppKit
import DiscShiftCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmingStop = false

    var body: some View {
        VStack(spacing: 0) {
            WizardProgressView()
            Divider()
            Group {
                switch model.step {
                case .source: SourceStepView()
                case .identify: ShowStepView()
                case .episodes: EpisodesStepView()
                case .library: LibraryStepView()
                case .review: ReviewStepView()
                case .exporting: ExportStepView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            navigation
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem {
                Button { model.showingActivity = true } label: { Label("Activity", systemImage: "waveform.path") }
                    .help("Show reader activity")
            }
            ToolbarItem {
                SettingsLink { Label("Settings", systemImage: "gearshape") }.help("DiscShift Settings")
            }
        }
        .sheet(isPresented: $model.showingActivity) { ActivityView().environmentObject(model) }
        .sheet(isPresented: $model.showingSetup) { SetupView(setup: model.setup).environmentObject(model) }
        .alert(model.step == .exporting ? "Export Stopped" : "Unable to Continue", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
            Button("Show Activity") { model.error = nil; model.showingActivity = true }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Stop exporting?", isPresented: $confirmingStop) {
            Button("Stop Export", role: .destructive) { model.cancel() }
            Button("Keep Exporting", role: .cancel) {}
        } message: { Text("Completed episodes will be kept. The current incomplete file will be removed.") }
    }

    private var navigation: some View {
        HStack(spacing: 16) {
            if model.step != .source && model.step != .exporting {
                Button("Back") { model.goBack() }.disabled(model.busy)
                    .keyboardShortcut("[", modifiers: .command)
            }
            if model.step == .review, let message = model.exportHint {
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } else if model.step == .episodes {
                Text("Next: choose where to save")
                    .font(.callout).foregroundStyle(.secondary)
            } else if model.step == .library {
                Text("Nothing is exported until the final step.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if model.step == .exporting {
                if model.busy {
                    Button("Stop Export…") { confirmingStop = true }
                } else {
                    if model.jobs.contains(where: { $0.status == "Complete" }) {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(model.jobs.filter { $0.status == "Complete" }.map(\.output))
                        }
                    }
                    if model.jobs.allSatisfy({ $0.status == "Complete" }) {
                        Button("Next Disc") { model.startNextDisc() }.keyboardShortcut(.defaultAction)
                    } else {
                        Button("Review Episodes") { model.step = model.choices.isEmpty ? .source : .episodes }.keyboardShortcut(.defaultAction)
                    }
                }
            } else if model.scanning {
                Button("Cancel Scan", role: .cancel) { model.cancel() }
            } else {
                Button(nextLabel) { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!primaryEnabled)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
    private var nextLabel: String {
        if model.step == .source && !model.readerAvailable { return "Set Up DiscShift…" }
        if model.step == .source && model.source == nil { return "Choose Source…" }
        if model.step == .source && model.choices.isEmpty { return "Scan Source" }
        if model.step == .identify { return model.enteringShowManually ? "Continue to Episodes" : "Use This Show" }
        if model.step == .episodes { return "Confirm Order & Continue" }
        if model.step == .library {
            if !model.episodeOrderConfirmed { return "Review Episode Order" }
            return model.destination == nil ? "Choose TV Library…" : "Review Export"
        }
        if model.step == .review { return "Export \(model.selectedCount) \(model.selectedCount == 1 ? "Episode" : "Episodes")" }
        return "Continue"
    }
    private var primaryEnabled: Bool {
        if model.busy { return false }
        if model.step == .source && !model.readerAvailable { return true }
        if model.step == .library || (model.step == .source && model.source == nil) { return true }
        return model.canContinue
    }
    private func advance() {
        if model.step == .source && !model.readerAvailable { model.openSetup() }
        else if model.step == .source && model.source == nil { model.chooseSource() }
        else if model.step == .library && !model.episodeOrderConfirmed { model.step = .episodes }
        else if model.step == .library && model.destination == nil { model.chooseDestination() }
        else { model.continueWizard() }
    }
}

private struct WizardProgressView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            ForEach(WizardStep.setup) { step in
                if step != .source {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(maxWidth: 24).frame(height: 1).accessibilityHidden(true)
                }
                Group {
                    if !model.busy && model.step != .exporting && step.rawValue < model.step.rawValue {
                        Button { model.navigate(to: step) } label: { indicator(step) }.buttonStyle(.plain)
                            .help("Go back to \(step.title.lowercased())")
                    } else {
                        indicator(step)
                    }
                }
            }
        }
        .frame(maxWidth: 760).padding(.horizontal, 28).padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }
    private func indicator(_ step: WizardStep) -> some View {
        HStack(spacing: 7) {
            Image(systemName: model.step.rawValue > step.rawValue ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle\(model.step == step ? ".fill" : "")")
                .font(.title3).foregroundStyle(model.step == step ? Color.accentColor : Color.secondary).accessibilityHidden(true)
            Text(step.title).fontWeight(model.step == step ? .semibold : .regular)
                .foregroundStyle(model.step == step ? Color.primary : Color.secondary)
                .accessibilityLabel("Step \(step.rawValue + 1), \(step.title)\(model.step == step ? ", current" : "")")
        }.fixedSize()
    }
}

struct StepHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title).fontWeight(.bold)
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SourceStepView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 64, weight: .light)).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text(model.scanning ? "Reading your source" : "Start with your disc")
                        .font(.largeTitle).fontWeight(.bold)
                    Text(model.scanning ? "DiscShift is finding the titles, chapters, and tracks. This can take a few minutes on a DVD." : "Bring your DVD episodes into Jellyfin. We’ll help you choose the titles, name the episodes, and save them to your library.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                if let source = model.source {
                    GroupBox {
                        HStack(spacing: 14) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: source.path)).resizable().frame(width: 40, height: 40).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.lastPathComponent).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                                Text(source.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 4)
                            if !model.scanning {
                                Button("Change…") { model.chooseSource() }
                            }
                        }.padding(10)
                    }
                    if model.scanning {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(model.detail).foregroundStyle(.secondary)
                        }.frame(height: 24)
                    } else {
                        Text("Choose Scan Source to find the titles in this source.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Choose Source…") { model.chooseSource() }.controlSize(.large)
                    Text("Choose a mounted DVD, VIDEO_TS folder, disc image, or video file.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if !model.readerAvailable {
                    GroupBox {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Set up your DVD reader").fontWeight(.semibold)
                                Text("We’ll help you find or install the reader before scanning a source.").foregroundStyle(.secondary)
                                Button("Set Up DiscShift…") { model.openSetup() }
                            }
                            Spacer()
                        }.padding(8)
                    }
                }
                if !model.scanning {
                    if model.automaticShowLookup {
                        Text("After scanning, show lookup sends the disc name to TVMaze. Your videos and local paths stay on this Mac.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    HStack(spacing: 18) {
                        Button("Find Mounted DVD") { model.discoverDisc() }
                    }.buttonStyle(.link).font(.callout)
                }
            }
            .frame(maxWidth: 560).padding(.horizontal, 32).padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ExportStepView: View {
    @EnvironmentObject private var model: AppModel
    private var success: Bool { !model.busy && !model.jobs.isEmpty && model.jobs.allSatisfy { $0.status == "Complete" } }
    private var completed: Int { model.jobs.filter { $0.status == "Complete" }.count }
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: model.busy ? "arrow.down.doc" : success ? "checkmark.circle.fill" : "pause.circle")
                    .font(.system(size: 52, weight: .light)).foregroundStyle(success ? Color.green : Color.accentColor).accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(model.busy ? "Saving your episodes" : success ? "Your episodes are ready" : "Export stopped")
                        .font(.title).fontWeight(.bold)
                    Text(model.busy ? model.detail : success ? "The completed files are ready for Jellyfin to scan." : "Completed episodes are safe in your library. Review your selection to try again.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                VStack(spacing: 10) {
                    if (model.busy || success), let codec = model.jobs.first?.encoder.codec {
                        let verified = model.jobs.contains { $0.hardwareEncoderID != nil }
                        Label(verified ? "\(model.busy ? "Mac hardware encoding" : "Encoded with Mac hardware") · \(codec)" : "Preparing \(codec) hardware encoder…", systemImage: verified ? "bolt.fill" : "cpu")
                            .font(.callout).foregroundStyle(verified ? Color.green : Color.secondary)
                    }
                    ProgressView(value: model.totalProgress)
                    HStack {
                        Text("\(completed) of \(model.jobs.count) \(model.jobs.count == 1 ? "episode" : "episodes") complete")
                        Spacer()
                        Text("\(Int(model.totalProgress * 100))%").monospacedDigit()
                    }.font(.callout).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(Array(model.jobs.enumerated()), id: \.element.id) { index, job in
                            if index > 0 { Divider().padding(.vertical, 12) }
                            HStack(spacing: 12) {
                                Image(systemName: job.status == "Complete" ? "checkmark.circle.fill" : job.status == "Failed" ? "exclamationmark.circle.fill" : "doc")
                                    .foregroundStyle(job.status == "Complete" ? Color.green : job.status == "Failed" ? Color.orange : Color.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(job.output.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                    if job.status == "Encoding" { ProgressView(value: job.progress) }
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(job.status)
                                    if let bytes = job.outputBytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                                }.font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(12)
                }
                if model.busy {
                    Label("You can keep using your Mac. DiscShift will keep it awake while exporting.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: 660).padding(32).frame(maxWidth: .infinity)
        }
    }
}

struct ReaderSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var advanced = false
    var body: some View {
        Form {
            UpdateSettingsView()
            Section {
                Label(model.readerAvailable ? "Reader installed" : "Reader needed", systemImage: model.readerAvailable ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(model.readerAvailable ? Color.secondary : Color.orange)
                Button("Run Setup Assistant…") {
                    openWindow(id: "main")
                    model.openSetup()
                }
            } header: { Text("DVD reader") } footer: {
                Text("Setup checks your reader and helps install anything missing.")
            }
            Section {
                Toggle("Automatically identify shows online", isOn: $model.automaticShowLookup)
            } header: { Text("Show identification") } footer: {
                Text("After scanning, DiscShift searches TVMaze using the disc name. Video, audio, and local paths are never uploaded. You can always enter show details manually.")
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("DiscShift uses HandBrakeCLI to read and encode video. Change its location if you installed your own copy.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            TextField("Reader executable", text: $model.executable).textFieldStyle(.roundedBorder)
                            Button("Choose…") { model.chooseEngine() }
                        }
                        TextField("DVD support folder", text: $model.libraryDirectory).textFieldStyle(.roundedBorder)
                        Text("Extra DVD support uses libdvdcss. The reader and DVD support must match your Mac’s architecture.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            }
        }
        .formStyle(.grouped).frame(width: 560, height: 650).disabled(model.busy || model.updateInstallationPending)
        .onChange(of: model.executable) { _, _ in model.saveSettings() }
        .onChange(of: model.libraryDirectory) { _, _ in model.saveSettings() }
        .onChange(of: model.automaticShowLookup) { _, _ in model.saveSettings() }
    }
}

private struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Reader Activity").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.activity, forType: .string)
                }.disabled(model.activity.isEmpty)
            }
            ScrollView {
                Text(model.activity.isEmpty ? "Reader diagnostics will appear here when you scan or export a source." : model.activity)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }.background(Color(nsColor: .textBackgroundColor)).border(Color(nsColor: .separatorColor))
            HStack {
                Text(model.busy ? "Updating as DiscShift works" : "All activity stays on this Mac").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 700, height: 480)
    }
}
