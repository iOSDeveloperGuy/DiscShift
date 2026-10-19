import SwiftUI
import AppKit

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var setup: DependencySetup
    @State private var page = 0
    @State private var advanced = false
    @State private var showingDetails = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                            .resizable().frame(width: 72, height: 72).accessibilityHidden(true)
                        Spacer()
                        Text("\(page + 1) of 3").font(.callout).foregroundStyle(.secondary)
                    }
                    if page == 0 { welcome }
                    else if page == 1 { reader }
                    else { ready }
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if page > 0 { Button("Back") { page -= 1 }.disabled(setup.isWorking) }
                Button("Set Up Later") { model.showingSetup = false }.disabled(setup.isWorking)
                Spacer()
                if setup.isWorking {
                    Button(setup.isInstalling ? "Stop Installation" : "Cancel Check") { setup.cancel() }
                } else {
                    Button(primaryLabel) { advance() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.controlSize(.large).padding(20)
        }
        .frame(width: 620, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(setup.isWorking)
    }
    private var primaryLabel: String {
        if page == 0 { return "Check My Mac" }
        if page == 1 { return setup.isReady ? "Continue" : "Check Again" }
        return "Start Using DiscShift"
    }
    private func advance() {
        if page == 0 { page = 1; setup.check() }
        else if page == 1 {
            if setup.isReady { page = 2 } else { setup.check() }
        } else { model.completeSetup() }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your discs. Your library.").font(.largeTitle).fontWeight(.bold)
            Text("Turn your DVD episodes into smaller, neatly named files for your TV library. Let’s get this Mac ready.")
                .font(.title3).foregroundStyle(.secondary)
            feature("opticaldisc", "Choose a disc", "DiscShift finds the titles on your DVD or in a video file.")
            feature("list.number", "Match your episodes", "Find the show online, then confirm the episode order.")
            feature("folder", "Save to your library", "Use Apple hardware encoding and the file type you prefer.")
            Text("Setup checks for a separate reader called HandBrakeCLI. If it’s missing, we’ll help you install it.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 3)
    }
    private var reader: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(setup.isReady ? "Your reader is ready" : "Get your Mac ready").font(.largeTitle).fontWeight(.bold)
            Text("HandBrakeCLI reads your discs and compresses video. It runs locally on your Mac.")
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        if setup.isWorking { ProgressView().controlSize(.small) }
                        else { Image(systemName: setup.isReady ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(setup.isReady ? .green : .secondary).font(.title2) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(setup.isInstalling ? "Installing…" : setup.isWorking ? "Checking your reader…" : setup.isReady ? setup.version ?? "DVD reader" : "DVD reader").fontWeight(.semibold)
                            Text(setup.isReady ? "Apple hardware encoding is available" : "Required for scanning and exporting").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if !setup.isReady && !setup.isWorking {
                        if ReaderLocations.brew != nil {
                            Button("Install Reader") { setup.install() }.controlSize(.large)
                            Text("Uses your existing Homebrew installation to download HandBrakeCLI and its required components.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Link("Download HandBrakeCLI…", destination: URL(string: "https://handbrake.fr/downloads2.php")!)
                            Text("Download the macOS command-line package from HandBrake. Open it, then choose HandBrakeCLI below. The graphical HandBrake app alone isn’t the reader DiscShift needs.").font(.callout).foregroundStyle(.secondary)
                        }
                        Button("Choose Downloaded Reader…") { setup.chooseReader() }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(setup.dvdLibraryFound ? "DVD support found" : "Extra DVD support", systemImage: setup.dvdLibraryFound ? "checkmark.circle" : "opticaldisc").fontWeight(.semibold)
                    Text(setup.dvdLibraryFound ? "libdvdcss was found. Your first disc scan will check whether it works with that DVD." : "Some DVDs need an additional library called libdvdcss. Video files and unprotected DVDs can work without it.").font(.callout).foregroundStyle(.secondary)
                    if !setup.dvdLibraryFound {
                        if ReaderLocations.brew != nil {
                            Button("Add DVD Support") { setup.install(dvdSupport: true) }.disabled(setup.isWorking)
                        } else {
                            HStack {
                                Link("About DVD support…", destination: URL(string: "https://www.videolan.org/developers/libdvdcss.html")!)
                                Link("Get Homebrew…", destination: URL(string: "https://brew.sh")!)
                            }
                            Text("If you install Homebrew, return here and choose Check Again to enable guided installation.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = setup.message {
                Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Reader location", text: $setup.readerPath).textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("DVD library folder", text: $setup.libraryPath).textFieldStyle(.roundedBorder)
                        Button("Choose…") { setup.chooseLibrary() }
                    }
                }.padding(.top, 10).disabled(setup.isWorking)
            }
            if !setup.diagnostics.isEmpty {
                DisclosureGroup("Installation and check details", isExpanded: $showingDetails) {
                    Text(setup.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
            }
        }
    }
    private var ready: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Ready for your first disc", systemImage: "checkmark.circle.fill")
                .font(.title).fontWeight(.bold).foregroundStyle(.green)
            Text("Insert a DVD or choose a video source. We’ll guide you through the rest.").font(.title3).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Find show details online", isOn: $model.automaticShowLookup)
                    Text("DiscShift sends the disc name or your search text to TVMaze. Your videos and local paths stay on this Mac. You’ll always confirm the episode order before exporting.").font(.callout).foregroundStyle(.secondary)
                    Link("About TVMaze", destination: URL(string: "https://www.tvmaze.com/api")!)
                }.padding(10)
            }
            Text("You can run setup again from the Help menu or Settings at any time.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
