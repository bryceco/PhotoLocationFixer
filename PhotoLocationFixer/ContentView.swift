import SwiftUI

struct ContentView: View {
    @State private var library = Library()
    @State private var worldMap = true
    @AppStorage("skipDistanceKm") private var skipKm = 100.0

    var body: some View {
        Group {
            switch library.state {
            case .loading:
                ProgressView("Reading photo library…")
            case .denied:
                Text("Allow full access in System Settings > Privacy & Security > Photos, then relaunch.")
            case .ready:
                browser
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .task { await library.load() }
        .alert("Couldn't Change Photo",
               isPresented: Binding(get: { library.errorMessage != nil },
                                    set: { if !$0 { library.errorMessage = nil } }))
        {} message: {
            Text(library.errorMessage ?? "")
        }
    }

    private var browser: some View {
        let index = library.selection
        let location = index.flatMap { library.entries[$0].location }
        let cluster = index.flatMap { library.cluster(around: $0) }

        return HSplitView {
            ThumbnailList(library: library)
                .frame(minWidth: 160, idealWidth: 180, maxWidth: 260)
            VStack {
                if let index {
                    AssetImage(asset: library.asset(at: index), pixels: 2000)
                        .id(index)
                    Text(summary(index: index, location: location, cluster: cluster))
                        .textSelection(.enabled)
                        .padding(.bottom, 8)
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            PhotoMap(location: location, cluster: cluster, world: worldMap)
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Previous Distant Photo", systemImage: "backward.end") {
                    library.skip(-1, beyondKm: skipKm)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                TextField("Distance", value: $skipKm, format: .number)
                    .frame(width: 60)
                Text("km")
                Button("Next Distant Photo", systemImage: "forward.end") {
                    library.skip(1, beyondKm: skipKm)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            }
            ToolbarItemGroup {
                Button("Previous Suspect", systemImage: "exclamationmark.arrow.triangle.2.circlepath") {
                    library.skipToSuspect(-1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Next Suspect", systemImage: "exclamationmark.triangle") {
                    library.skipToSuspect(1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }
            ToolbarItemGroup {
                Button("Flip Longitude", systemImage: "arrow.left.arrow.right") {
                    Task { await library.flipSelected() }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(location == nil)
                Picker("Map", selection: $worldMap) {
                    Text("World").tag(true)
                    Text("Zoomed").tag(false)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func summary(index: Int, location: Coord?, cluster: Cluster?) -> String {
        var lines = ["\(index + 1) of \(library.entries.count)"]
        guard let location else {
            return lines[0] + "\nNo location"
        }
        lines.append(String(format: "%.4f, %.4f", location.lat, location.lon))
        if let cluster {
            lines.append("\(cluster.count) of \(cluster.total) photos within 12 hours are in the circle")
            lines.append(String(format: "Photo is %.0f km from it; mirror is %.0f km",
                                location.km(to: cluster.center),
                                location.mirror.km(to: cluster.center)))
        } else {
            lines.append("No other located photos within 12 hours")
        }
        return lines.joined(separator: "\n")
    }
}

#Preview {
    ContentView()
}
