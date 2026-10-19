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
                if page == 1 && !setup.isReady && !setup.isWorking && ReaderLocations.brew != nil {
                    Button("Check Again") { setup.check() }
                }
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
        if page == 1 {
            if setup.isReady { return "Continue" }
            return ReaderLocations.brew != nil ? "Install DVD Reader" : "Check Again"
        }
        return "Start Using DiscShift"
    }
    private func advance() {
        if page == 0 { page = 1; setup.check() }
        else if page == 1 {
            if setup.isReady { page = 2 }
            else if ReaderLocations.brew != nil { setup.install() }
            else { setup.check() }
        } else { model.completeSetup() }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your discs. Your library.").font(.largeTitle).fontWeight(.bold)
            Text("Turn your DVD episodes into smaller, neatly named files for your TV library. Let’s get this Mac ready.")
                .font(.title3).foregroundStyle(.secondary)
            feature("opticaldisc", "Choose a disc", "DiscShift finds the titles on your DVD or in a video file.")
            feature("list.number", "Match your episodes", "Find the show online, then confirm the episode order.")
            feature("folder", "Save to your library", "Save smaller, neatly named videos in the format you prefer.")
            Text("We’ll check your Mac and help you install anything you need to get started.")
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
            Text(setup.isReady ? "Your Mac is ready" : "Get your Mac ready")
                .font(.largeTitle).fontWeight(.bold)
            Text(setup.isReady ? "Your reader is installed. You’re ready to choose a disc or video." : "DiscShift needs a reader to open DVDs and save your videos. We’ll check what’s ready and help with anything missing.")
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        if setup.isWorking { ProgressView().controlSize(.small) }
                        else {
                            Image(systemName: setup.isReady ? "checkmark.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(setup.isReady ? .green : .secondary).font(.title2)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(setup.isInstalling ? "Installing your reader…" : setup.isWorking ? "Checking your Mac…" : setup.isReady ? "Reader ready" : "DVD reader")
                                .fontWeight(.semibold)
                            Text(setup.isInstalling ? "Downloading and setting up what your Mac needs." : setup.isWorking ? "This should only take a moment." : setup.isReady ? "Ready to scan and export your videos." : "One install gets your Mac ready.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if setup.isReady && setup.dvdLibraryFound {
                        Label("DVD support is included", systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !setup.isReady && !setup.isWorking {
                        if ReaderLocations.brew != nil {
                            Text("Installs the reader and its included DVD support together. We’ll check everything when it finishes.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Link("Download Reader…", destination: URL(string: "https://handbrake.fr/downloads2.php")!)
                            Text("Choose the HandBrakeCLI download for macOS, then select the downloaded reader in Advanced below.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            // Reader installation may already include DVD support. Offer another
            // action only after checking the installed reader and its libraries.
            if setup.isReady && !setup.dvdLibraryFound {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Extra help for some DVDs", systemImage: "opticaldisc").fontWeight(.semibold)
                        Text("You can start with videos and unprotected DVDs now. If a DVD won’t open, try adding DVD support here.")
                            .font(.callout).foregroundStyle(.secondary)
                        if ReaderLocations.brew != nil {
                            Button("Add DVD Support") { setup.install(dvdSupport: true) }.disabled(setup.isWorking)
                        } else {
                            Link("About DVD support…", destination: URL(string: "https://www.videolan.org/developers/libdvdcss.html")!)
                            Text("Advanced below has the installation details and options for choosing an existing copy.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let message = setup.message {
                Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("DiscShift uses HandBrakeCLI to read and encode video. Guided installation uses your existing Homebrew and includes the reader’s dependencies.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let version = setup.version { LabeledContent("Reader version", value: version) }
                    HStack {
                        TextField("Reader executable", text: $setup.readerPath).textFieldStyle(.roundedBorder)
                        Button("Choose…") { setup.chooseReader() }.help("Choose HandBrakeCLI")
                    }
                    Link("Download HandBrakeCLI…", destination: URL(string: "https://handbrake.fr/downloads2.php")!)
                    Divider()
                    Text("Extra DVD support uses libdvdcss. If you installed it in another location, choose its containing folder.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("DVD support folder", text: $setup.libraryPath).textFieldStyle(.roundedBorder)
                        Button("Choose…") { setup.chooseLibrary() }.help("Choose the DVD support folder")
                    }
                    if ReaderLocations.brew == nil {
                        Link("Get Homebrew…", destination: URL(string: "https://brew.sh")!)
                        Text("After installing Homebrew, choose Check Again to enable guided installation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 10).disabled(setup.isWorking)
            }
            if !setup.diagnostics.isEmpty {
                DisclosureGroup("Details", isExpanded: $showingDetails) {
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
