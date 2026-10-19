import SwiftUI
import DiscDockCore

struct ShowStepView: View {
    @EnvironmentObject private var model: AppModel
    private var selection: Binding<Int?> {
        Binding(get: { model.identifiedShow?.id }, set: { id in
            if let show = model.showMatches.first(where: { $0.id == id }) { model.selectShow(show) }
        })
    }
    var body: some View {
        Group {
            if model.enteringShowManually { manualEntry }
            else { search }
        }.padding(28)
    }
    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeading(title: "Name your show", subtitle: "Use the title Jellyfin should match. Add the original release year if you know it.")
            GroupBox {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Series title").fontWeight(.medium)
                        TextField("Series title", text: $model.series, prompt: Text("Enter the show name"))
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Release year").fontWeight(.medium)
                        TextField("Release year", text: $model.year, prompt: Text("Optional"))
                            .textFieldStyle(.roundedBorder).frame(width: 130)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: 560)
            Button("Search Online Instead") { model.returnToShowSearch() }.buttonStyle(.link)
            Spacer()
            Label("You’ll set the season and episode numbers next.", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var search: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                StepHeading(title: "Find your show", subtitle: "Choose the right version. We’ll fill in the details and load episode names.")
                Button("Enter Manually") { model.enterShowManually() }
            }
            HStack(spacing: 12) {
                TextField("Show name", text: $model.searchQuery, prompt: Text("Search for a TV show"))
                    .textFieldStyle(.roundedBorder).onSubmit { model.searchShows() }
                Button("Search") { model.searchShows() }
                    .disabled(model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.lookingUpShow { ProgressView().controlSize(.small) }
            }
            if model.showMatches.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tv").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                    Text(model.lookingUpShow ? "Looking for matching shows…" : "Search by show name")
                        .font(.headline)
                    Text("Try the show’s name, without a season or disc number.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.showMatches, selection: selection) { show in
                    HStack(spacing: 14) {
                        Image(systemName: "tv").font(.title2).foregroundStyle(.secondary).frame(width: 36)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(show.name).fontWeight(.semibold)
                            Text(show.detail).font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 7).tag(show.id)
                }.listStyle(.inset)
                    .border(Color(nsColor: .separatorColor))
            }
            if let message = model.metadataMessage {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Only the disc name or search text is sent online.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("Metadata by TVMaze", destination: URL(string: "https://www.tvmaze.com")!).font(.caption)
            }
        }
    }
}
