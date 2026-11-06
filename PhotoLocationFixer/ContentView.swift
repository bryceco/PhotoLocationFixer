import SwiftUI

struct ContentView: View {
    @State private var library = Library()
    @State private var worldMap = true
    @AppStorage("skipDistanceKm") private var skipKm = 100.0
    @AppStorage("batchKm") private var batchKm = 100.0
    @AppStorage("batchHours") private var batchHours = 24.0
    @State private var batch: [Int]?

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
        .confirmationDialog("Flip \(batch?.count ?? 0) photos?",
                            isPresented: Binding(get: { batch != nil }, set: { if !$0 { batch = nil } }),
                            titleVisibility: .visible)
        {
            Button("Flip Longitude of \(batch?.count ?? 0) Photos") {
                if let batch {
                    Task { await library.flip(batch) }
                }
            }
        } message: {
            Text("Every photo within \(batchKm.formatted()) km and \(batchHours.formatted()) hours of the selected photo will have its longitude reversed. Each change is logged and can be flipped back.")
        }
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
            PhotoMap(location: location, cluster: cluster, world: worldMap, longJumpKm: skipKm)
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: library.selection) { library.saveSelection() }
        .toolbar {
            ToolbarItemGroup {
                Button("Previous Distant Photo", systemImage: "backward.end") {
                    library.skip(-1, beyondKm: skipKm)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help("Go back to the previous photo more than this distance from the current one (⌘←)")
                TextField("Distance", value: $skipKm, format: .number)
                    .frame(width: 60)
                    .help("How far away, in kilometers, a photo must be for the skip buttons to stop at it")
                Text("km")
                Button("Next Distant Photo", systemImage: "forward.end") {
                    library.skip(1, beyondKm: skipKm)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .help("Go forward to the next photo more than this distance from the current one (⌘→)")
            }
            ToolbarItemGroup {
                Button("Previous Suspect", systemImage: "exclamationmark.arrow.triangle.2.circlepath") {
                    library.skipToSuspect(-1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .help("Go back to the previous photo that is outside its circle while its mirror is inside (⌥⌘←)")
                Button("Next Suspect", systemImage: "exclamationmark.triangle") {
                    library.skipToSuspect(1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .help("Go forward to the next photo that is outside its circle while its mirror is inside (⌥⌘→)")
            }
            ToolbarItemGroup {
                Button("Flip Longitude", systemImage: "arrow.left.arrow.right") {
                    Task { await library.flipSelected() }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(location == nil)
                .help("Reverse this photo's longitude in the Photos library; do it again to undo (⇧⌘F)")
                Button("Flip Nearby Photos…", systemImage: "arrow.left.arrow.right.square") {
                    batch = library.nearbySelected(km: batchKm, hours: batchHours)
                }
                .disabled(location == nil)
                .help("Reverse the longitude of every photo within the distance and time below of this photo, after confirming")
                TextField("km", value: $batchKm, format: .number)
                    .frame(width: 50)
                    .help("Batch flip: distance from the selected photo, in kilometers")
                Text("km")
                TextField("hours", value: $batchHours, format: .number)
                    .frame(width: 40)
                    .help("Batch flip: time from the selected photo, in hours")
                Text("h")
                Picker("Map", selection: $worldMap) {
                    Text("World").tag(true)
                    Text("Zoomed").tag(false)
                }
                .pickerStyle(.segmented)
                .help("World shows the photo and its mirror on the whole map; Zoomed follows the photo at the zoom you choose")
            }
        }
    }

    private func summary(index: Int, location: Coord?, cluster: Cluster?) -> String {
        var lines = ["\(index + 1) of \(library.entries.count)", library.filename(at: index)]
        guard let location else {
            return (lines + ["No location"]).joined(separator: "\n")
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
