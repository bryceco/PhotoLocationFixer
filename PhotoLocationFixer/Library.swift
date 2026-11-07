import AppKit
import CoreLocation
import Observation
import Photos

nonisolated struct Coord: Sendable, Equatable {
    var lat: Double
    var lon: Double

    /// The same point with its longitude sign reversed.
    var mirror: Coord { Coord(lat: lat, lon: -lon) }

    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    func km(to other: Coord) -> Double {
        let p1 = lat * .pi / 180, p2 = other.lat * .pi / 180
        let dLat = p2 - p1, dLon = (other.lon - lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(p1) * cos(p2) * sin(dLon / 2) * sin(dLon / 2)
        return 12742 * asin(min(1, sqrt(h)))
    }

    static func mean(_ points: [Coord]) -> Coord {
        Coord(lat: points.map(\.lat).reduce(0, +) / Double(points.count),
              lon: points.map(\.lon).reduce(0, +) / Double(points.count))
    }
}

nonisolated struct Entry: Sendable {
    let id: String
    let date: Date
    var location: Coord?
}

/// Where most of the photos taken around the same time are.
struct Cluster {
    let center: Coord
    let radiusKm: Double
    let count: Int // photos in the cluster
    let total: Int // photos with a location in the time window
}

@Observable final class Library {
    enum State { case loading, denied, ready }

    private(set) var state = State.loading
    private(set) var entries: [Entry] = []
    var selection: Int?
    var errorMessage: String?

    private var assets = PHFetchResult<PHAsset>()

    /// Photos this close in time to a photo count as taken "that day".
    private let window: TimeInterval = 12 * 60 * 60

    // MARK: Loading

    private nonisolated struct Loaded: @unchecked Sendable {
        let assets: PHFetchResult<PHAsset>
        let entries: [Entry]
    }

    func load() async {
        guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized else {
            state = .denied
            return
        }
        let loaded = await Task.detached { Library.buildIndex() }.value
        assets = loaded.assets
        entries = loaded.entries
        selection = entries.isEmpty ? nil : 0
        if let saved = UserDefaults.standard.object(forKey: Self.selectionKey) as! Double? {
            let date = Date(timeIntervalSinceReferenceDate: saved)
            selection = entries.firstIndex { $0.date >= date } ?? selection
        }
        state = .ready
    }

    private static let selectionKey = "selectedPhotoDate"

    /// Remember the selected photo, by its date, for the next launch.
    func saveSelection() {
        if let selection {
            UserDefaults.standard.set(entries[selection].date.timeIntervalSinceReferenceDate,
                                      forKey: Self.selectionKey)
        }
    }

    private nonisolated static func buildIndex() -> Loaded {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var entries: [Entry] = []
        entries.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            let c = asset.location?.coordinate
            entries.append(Entry(id: asset.localIdentifier,
                                 date: asset.creationDate ?? .distantPast,
                                 location: c.map { Coord(lat: $0.latitude, lon: $0.longitude) }))
        }
        return Loaded(assets: assets, entries: entries)
    }

    func asset(at index: Int) -> PHAsset {
        assets.object(at: index)
    }

    /// The name the photo's file had when it was added to the library.
    func filename(at index: Int) -> String {
        let resources = PHAssetResource.assetResources(for: asset(at: index))
        let original = resources.first { $0.type == .photo } ?? resources.first
        return original?.originalFilename ?? "No filename"
    }

    // MARK: Navigation

    /// Select the next photo (in `direction`, +1 or -1) for which `test` is true.
    private func seek(_ direction: Int, where test: (Int) -> Bool) {
        var i = (selection ?? -direction) + direction
        while entries.indices.contains(i) {
            if test(i) {
                selection = i
                return
            }
            i += direction
        }
        NSSound.beep()
    }

    /// Skip to the next photo more than `km` from the current one.
    func skip(_ direction: Int, beyondKm km: Double) {
        let origin = selection.flatMap { entries[$0].location }
        seek(direction) { i in
            guard let location = entries[i].location else { return false }
            guard let origin else { return true }
            return location.km(to: origin) > km
        }
    }

    /// Skip to the next photo that is away from its cluster while its mirror is inside it.
    func skipToSuspect(_ direction: Int) {
        seek(direction) { isSuspect($0) }
    }

    func isSuspect(_ index: Int) -> Bool {
        guard let location = entries[index].location,
              let cluster = cluster(around: index)
        else { return false }
        let reach = cluster.radiusKm + 50
        return location.km(to: cluster.center) > reach
            && location.mirror.km(to: cluster.center) <= reach
    }

    // MARK: Cluster

    func cluster(around index: Int) -> Cluster? {
        let date = entries[index].date
        var points: [Coord] = []
        for direction in [-1, 1] {
            var i = index + direction
            while entries.indices.contains(i),
                  abs(entries[i].date.timeIntervalSince(date)) <= window
            {
                if let location = entries[i].location {
                    points.append(location)
                }
                i += direction
            }
        }
        guard !points.isEmpty else { return nil }

        // Start from the fullest one-degree cell, then take everything near it.
        var cells: [Int: [Coord]] = [:]
        for p in points {
            cells[Int(p.lat.rounded(.down)) * 1000 + Int(p.lon.rounded(.down)), default: []].append(p)
        }
        let seed = Coord.mean(cells.values.max { $0.count < $1.count }!)
        let members = points.filter { $0.km(to: seed) <= 100 }
        let center = Coord.mean(members)
        let radius = members.map { $0.km(to: center) }.max()!
        return Cluster(center: center, radiusKm: max(radius, 10), count: members.count, total: points.count)
    }

    // MARK: Editing

    /// The selected photo and every located photo within `km` and `hours` of it.
    func nearbySelected(km: Double, hours: Double) -> [Int] {
        guard let index = selection, let origin = entries[index].location else { return [] }
        let date = entries[index].date
        var result: [Int] = []
        for direction in [-1, 1] {
            var i = index + direction
            while entries.indices.contains(i),
                  abs(entries[i].date.timeIntervalSince(date)) <= hours * 3600
            {
                if let location = entries[i].location, location.km(to: origin) <= km {
                    result.append(i)
                }
                i += direction
            }
        }
        return [index] + result
    }

    /// Reverse the longitude of the selected photo in the Photos library.
    func flipSelected() async {
        if let index = selection {
            await flip([index])
        }
    }

    /// Reverse the longitude of these photos in the Photos library, as one change.
    func flip(_ indices: [Int]) async {
        let ids = indices.map { entries[$0].id }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }

        var changes: [(index: Int, asset: PHAsset, new: CLLocation)] = []
        for index in indices {
            guard let location = entries[index].location, let asset = assets[entries[index].id] else { continue }
            guard asset.canPerform(.properties) else {
                errorMessage = "Photos doesn't allow photo \(index + 1) to be changed. Nothing was changed."
                return
            }
            let old = asset.location
            changes.append((index, asset, CLLocation(coordinate: location.mirror.cl,
                                                     altitude: old?.altitude ?? 0,
                                                     horizontalAccuracy: old?.horizontalAccuracy ?? 0,
                                                     verticalAccuracy: old?.verticalAccuracy ?? -1,
                                                     timestamp: old?.timestamp ?? entries[index].date)))
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for change in changes {
                    PHAssetChangeRequest(for: change.asset).location = change.new
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let stamp = Date().ISO8601Format()
        var lines = ""
        for change in changes {
            let location = entries[change.index].location!
            entries[change.index].location = location.mirror
            lines += "\(stamp)\t\(entries[change.index].id)\t\(location.lat)\t\(location.lon)\t\(location.lat)\t\(-location.lon)\n"
        }
        log(lines)
    }

    // MARK: Date repair

    /// A JPG whose date should be copied from the HEIC it was made from.
    nonisolated struct DateFix: Sendable {
        let id: String
        let name: String
        let from: Date
        let to: Date
    }

    /// Progress through the library while proposing date fixes, 0...1.
    var dateScanProgress: Double?

    /// Find JPGs that share a name with a HEIC taken up to `days` earlier.
    /// Reads every photo's filename, which takes a while; progress is reported
    /// in `dateScanProgress`. Also writes the proposals to date-fixes.tsv.
    func proposeDateFixes(days: Double) async -> [DateFix] {
        dateScanProgress = 0
        let entries = entries
        let assets = assets
        let progress: @Sendable (Double) -> Void = { p in
            Task { @MainActor in self.dateScanProgress = p }
        }
        let fixes = await Task.detached {
            Self.findDateFixes(entries: entries, assets: assets, days: days, progress: progress)
        }.value
        dateScanProgress = nil
        log(fixes.map { "\($0.id)\t\($0.name)\t\($0.from.ISO8601Format())\t\($0.to.ISO8601Format())\n" }.joined(),
            to: "date-fixes.tsv", replace: true)
        return fixes
    }

    private nonisolated static func findDateFixes(entries: [Entry], assets: PHFetchResult<PHAsset>,
                                                  days: Double, progress: @Sendable (Double) -> Void) -> [DateFix]
    {
        var heics: [String: [Int]] = [:]  // base name -> indices, in date order
        var jpgs: [(index: Int, base: String, name: String)] = []
        for index in entries.indices {
            if index % 1000 == 0 {
                progress(Double(index) / Double(entries.count))
            }
            let resources = PHAssetResource.assetResources(for: assets.object(at: index))
            guard let resource = resources.first(where: { $0.type == .photo }) ?? resources.first else { continue }
            let name = resource.originalFilename as NSString
            let base = name.deletingPathExtension.uppercased()
            switch name.pathExtension.uppercased() {
            case "HEIC": heics[base, default: []].append(index)
            case "JPG", "JPEG": jpgs.append((index, base, name as String))
            default: break
            }
        }
        var fixes: [DateFix] = []
        for jpg in jpgs {
            let date = entries[jpg.index].date
            let earlier = (heics[jpg.base] ?? []).filter {
                let gap = date.timeIntervalSince(entries[$0].date)
                return gap > 0 && gap <= days * 86400
            }
            // Two cameras share a numbering sequence, so insist on exactly one match.
            guard earlier.count == 1 else { continue }
            fixes.append(DateFix(id: entries[jpg.index].id, name: jpg.name,
                                 from: date, to: entries[earlier[0]].date))
        }
        return fixes
    }

    /// Apply date fixes to the Photos library, then rebuild the index since the order changed.
    func apply(_ fixes: [DateFix]) async {
        let stamp = Date().ISO8601Format()
        for chunk in stride(from: 0, to: fixes.count, by: 500).map({ Array(fixes[$0 ..< min($0 + 500, fixes.count)]) }) {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: chunk.map(\.id), options: nil)
            var assets: [String: PHAsset] = [:]
            fetched.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for fix in chunk {
                        if let asset = assets[fix.id], asset.canPerform(.properties) {
                            PHAssetChangeRequest(for: asset).creationDate = fix.to
                        }
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                break
            }
            log(chunk.map { "\(stamp)\t\($0.id)\t\($0.from.ISO8601Format())\t\($0.to.ISO8601Format())\n" }.joined(),
                to: "date-changes.tsv")
        }
        saveSelection()
        state = .loading
        await load()
    }

    /// Append to the record of every change made: time, photo, old lat/lon, new lat/lon.
    private func log(_ line: String, to name: String = "changes.tsv", replace: Bool = false) {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        if replace {
            try? Data(line.utf8).write(to: url)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
