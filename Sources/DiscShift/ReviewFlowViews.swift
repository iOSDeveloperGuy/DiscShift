import AppKit
import DiscShiftCore
import SwiftUI

struct EpisodesStepView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingNumbering = false
    @State private var startingEpisode = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeading(
                title: "Review your episodes",
                subtitle: "Match each DVD title to an episode. Check the order against your DVD menu before continuing."
            )
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.series).font(.headline).lineLimit(1)
                    HStack(spacing: 8) {
                        if !model.year.isEmpty { Text(model.year) }
                        Button("Change Show") { model.navigate(to: .identify) }.buttonStyle(.link).foregroundStyle(
                            Color.accentColor)
                    }.font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.availableSeasons.isEmpty {
                    Picker("Season", selection: $model.season) {
                        if !model.availableSeasons.contains(0) { Text("Specials").tag(0) }
                        if model.season != 0 && !model.availableSeasons.contains(model.season) {
                            Text("Season \(model.season)").tag(model.season)
                        }
                        ForEach(model.availableSeasons, id: \.self) { Text("Season \($0)").tag($0) }
                    }.fixedSize()
                } else {
                    Stepper("Season \(model.season)", value: $model.season, in: 0...999)
                        .accessibilityLabel("Season").fixedSize()
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

            HStack {
                Text("\(model.selectedCount) of \(model.choices.count) titles included").font(.callout).foregroundStyle(
                    .secondary)
                Spacer()
                Menu {
                    Button("Include All Titles") { for i in model.choices.indices { model.choices[i].selected = true } }
                    Button("Exclude All Titles") {
                        for i in model.choices.indices { model.choices[i].selected = false }
                    }
                    Divider()
                    Toggle("Enter Episode Numbers Manually", isOn: $model.manualEpisodeNumbers)
                } label: {
                    Text("Options")
                }.menuStyle(.borderlessButton).fixedSize()
                Button("Numbering…") {
                    startingEpisode = model.firstEpisode
                    showingNumbering = true
                }
                .popover(isPresented: $showingNumbering) { numbering }
            }
            Table(model.choices) {
                TableColumn("Include") { item in
                    Toggle("Include title \(item.id)", isOn: selected(item.id))
                        .labelsHidden().toggleStyle(.checkbox)
                }.width(48)
                TableColumn("DVD title") { item in
                    HStack(spacing: 8) {
                        Image(systemName: "film").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Title \(String(format: "%02d", item.id))")
                            Text(item.title.duration < 1200 ? "Possible extra" : "\(item.title.chapters) chapters")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }.width(min: 130, ideal: 150)
                TableColumn("Duration") { item in Text(item.title.time).monospacedDigit().foregroundStyle(.secondary) }
                    .width(75)
                TableColumn("Episode") { item in
                    if !item.selected {
                        Text("Not included").foregroundStyle(.tertiary)
                    } else if !model.currentCatalog.isEmpty && !model.manualEpisodeNumbers {
                        Picker("Episode for title \(item.id)", selection: episode(item.id)) {
                            if !model.currentCatalog.contains(where: { $0.number == item.episode }) {
                                Text("Episode \(item.episode) · not listed").tag(item.episode)
                            }
                            ForEach(model.currentCatalog) { entry in Text(entry.label).tag(entry.number!) }
                        }.labelsHidden().accessibilityLabel("Episode for title \(item.id)")
                            .accessibilityElement(children: .contain)
                    } else {
                        HStack(spacing: 8) {
                            Text("Episode").foregroundStyle(.secondary)
                            TextField(
                                "Episode for title \(item.id)", value: episode(item.id),
                                format: .number.grouping(.never)
                            )
                            .textFieldStyle(.roundedBorder).frame(width: 66).labelsHidden()
                            .accessibilityLabel("Episode for title \(item.id)").accessibilityElement(children: .contain)
                        }
                    }
                }.width(min: 260, ideal: 390)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .border(Color(nsColor: .separatorColor))
            if let message = model.episodeValidationMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(
                        model.currentCatalog.isEmpty
                            ? "Episode numbers determine the filenames. Only included titles will be saved."
                            : "Episode names follow broadcast order. DVD order can be different."
                    )
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let show = model.matchingShow { Link("TVMaze", destination: show.pageURL) }
                }.font(.callout)
            }
        }.padding(28)
    }
    private var numbering: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Number episodes in sequence").font(.headline)
            Text("Applies to included titles, from top to bottom.").foregroundStyle(.secondary)
            HStack {
                Text("Start at episode")
                TextField("Starting episode", value: $startingEpisode, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 64)
            }
            HStack {
                Button("Cancel") { showingNumbering = false }
                Spacer()
                Button("Apply Numbers") {
                    model.firstEpisode = startingEpisode
                    model.renumber()
                    showingNumbering = false
                }.disabled(!(1...999).contains(startingEpisode))
            }
        }.padding(20).frame(width: 310)
    }
    private func selected(_ id: Int) -> Binding<Bool> {
        Binding(
            get: { model.choices.first { $0.id == id }?.selected ?? false },
            set: { value in
                if let i = model.choices.firstIndex(where: { $0.id == id }) { model.choices[i].selected = value }
            })
    }
    private func episode(_ id: Int) -> Binding<Int> {
        Binding(
            get: { model.choices.first { $0.id == id }?.episode ?? 1 },
            set: { value in
                if let i = model.choices.firstIndex(where: { $0.id == id }) { model.choices[i].episode = value }
            })
    }
}

struct LibraryStepView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                StepHeading(
                    title: "Choose where to save",
                    subtitle:
                        "Select the TV Shows folder Jellyfin watches. We’ll create the show and season folders inside it."
                )
                DestinationCard()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Folder preview").font(.headline)
                    VStack(alignment: .leading, spacing: 12) {
                        Label(model.destination?.lastPathComponent ?? "Your TV library", systemImage: "folder")
                            .foregroundStyle(.secondary)
                        Label(showFolder, systemImage: "folder").padding(.leading, 22)
                        Label(String(format: "Season %02d", model.season), systemImage: "folder").padding(.leading, 44)
                        if let preview = model.filenamePreview?.components(separatedBy: "/").last {
                            Label(preview, systemImage: "doc").font(.callout).padding(.leading, 66).lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                HStack(spacing: 12) {
                    Image(systemName: model.episodeOrderConfirmed ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(model.episodeOrderConfirmed ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            model.episodeOrderConfirmed
                                ? "\(model.selectedCount) \(model.selectedCount == 1 ? "episode" : "episodes") · order confirmed"
                                : "Episode order needs another look"
                        ).fontWeight(.medium)
                        Text(
                            model.episodeOrderConfirmed
                                ? "You can review everything once more before exporting."
                                : "The show or assignments changed since your last review."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review Episodes") { model.step = .episodes }
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: 680).padding(28).frame(maxWidth: .infinity)
        }
    }
    private var showFolder: String { model.filenamePreview?.components(separatedBy: "/").first ?? model.series }
}

struct DestinationCard: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "folder.fill").font(.system(size: 36)).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.destination?.lastPathComponent ?? "No library folder selected").font(.headline)
                if let destination = model.destination {
                    Text(destination.path).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(destination.path)
                } else {
                    Text("Choose an existing TV library, or create a new folder.").font(.callout).foregroundStyle(
                        .secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.destination != nil { Button("Change Folder…") { model.chooseDestination() } }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

struct ReviewStepView: View {
    @EnvironmentObject private var model: AppModel
    @State private var advanced = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StepHeading(
                    title: "Ready to export",
                    subtitle:
                        "\(model.series)\(model.year.isEmpty ? "" : " (\(model.year))") · Season \(model.season) · \(model.selectedCount) \(model.selectedCount == 1 ? "episode" : "episodes")"
                )
                DestinationCard()
                HStack {
                    Label("Episode order confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit Episodes") { model.step = .episodes }
                }.font(.callout)
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(Array(model.choices.filter(\.selected).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.vertical, 8) }
                            HStack(spacing: 12) {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(
                                        MediaNaming.relativePath(
                                            series: model.series, year: model.year, season: model.season,
                                            episode: item.episode, container: model.container
                                        ).components(separatedBy: "/").last ?? ""
                                    )
                                    .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                    Text(
                                        "DVD title \(item.id)\(model.episodeMetadata(item.episode).map { " · " + $0.name } ?? "")"
                                    )
                                    .font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("About \(model.estimatedSize(for: item.title))")
                                    Text(item.title.time).monospacedDigit()
                                }.font(.callout).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }
                    }.padding(10)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Picker("File type", selection: $model.container) {
                                ForEach(ExportContainer.allCases) { Text($0.title).tag($0) }
                            }.fixedSize()
                            Spacer()
                            Label("Mac hardware encoding", systemImage: "bolt.fill").font(.callout).foregroundStyle(
                                .secondary)
                        }
                        HStack {
                            Picker("Video codec", selection: $model.encoder) {
                                ForEach(VideoEncoder.allCases) { Text($0.title).tag($0) }
                            }.fixedSize()
                            Spacer()
                            Picker("File size", selection: $model.profile) {
                                ForEach(VideoProfile.allCases) { Text($0.title).tag($0) }
                            }.fixedSize()
                        }
                        Text(model.container.detail)
                            .font(.caption).foregroundStyle(.secondary)
                        Text(
                            "About \(ByteCountFormatter.string(fromByteCount: model.estimatedExportBytes, countStyle: .file)) total"
                        )
                        .font(.callout).fontWeight(.medium)
                        Toggle("Eject disc when finished", isOn: $model.ejectAfter).toggleStyle(.checkbox)
                        DisclosureGroup("More export options", isExpanded: $advanced) {
                            Picker("Deinterlacing", selection: $model.filter) {
                                Text("Automatic (adaptive)").tag(MotionFilter.adaptive)
                                Text("Smoother motion (bob)").tag(MotionFilter.bob)
                                Text("Off").tag(MotionFilter.off)
                            }.fixedSize().padding(.top, 8)
                        }
                    }.padding(10)
                }
                if !model.container.supportsPictureSubtitles && model.hasPictureSubtitles {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(
                                model.needsSubtitleDecision
                                    ? "Picture subtitles need a choice" : "Picture subtitles will be left out",
                                systemImage: "captions.bubble"
                            )
                            .fontWeight(.semibold)
                            Text(
                                "\(model.container.title) can keep text captions, but not selectable picture subtitles. MKV keeps both."
                            )
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Keep All in MKV") { model.container = .mkv }
                                if model.needsSubtitleDecision {
                                    Button("Leave Out Picture Subtitles") { model.leaveOutPictureSubtitles() }
                                }
                            }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text(
                    "Size estimates include audio and may vary. Chapters and compatible audio/subtitles are kept. Existing files are never replaced."
                )
                .font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.profile) { _, _ in model.saveSettings() }
        .onChange(of: model.encoder) { _, _ in model.saveSettings() }
        .onChange(of: model.container) { _, _ in model.saveSettings() }
        .onChange(of: model.filter) { _, _ in model.saveSettings() }
        .onChange(of: model.ejectAfter) { _, _ in model.saveSettings() }
    }
}
