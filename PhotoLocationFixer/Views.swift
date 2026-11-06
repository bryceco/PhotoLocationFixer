import MapKit
import Photos
import SwiftUI

/// An image from the photo library, shown as soon as any version of it is available.
struct AssetImage: View {
    let asset: PHAsset
    let pixels: CGFloat

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .task {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            PHImageManager.default().requestImage(for: asset,
                                                  targetSize: CGSize(width: pixels, height: pixels),
                                                  contentMode: .aspectFit,
                                                  options: options)
            { result, _ in
                if let result {
                    image = result
                }
            }
        }
    }
}

struct ThumbnailList: View {
    @Bindable var library: Library

    var body: some View {
        ScrollViewReader { proxy in
            List(library.entries.indices, id: \.self, selection: $library.selection) { index in
                let entry = library.entries[index]
                HStack {
                    AssetImage(asset: library.asset(at: index), pixels: 120)
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading) {
                        Text(entry.date, format: .dateTime.year().month().day())
                        Text(entry.date, format: .dateTime.hour().minute())
//                        Text(library.filename(at: index))
                        if entry.location == nil {
                            Text("No location")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
            .onChange(of: library.selection, initial: true) { _, selection in
                if let selection {
                    proxy.scrollTo(selection)
                }
            }
        }
    }
}

struct PhotoMap: View {
    let location: Coord?
    let cluster: Cluster?
    let world: Bool
    /// In the world view, a move further than this zooms all the way back out.
    let longJumpKm: Double

    @State private var camera = MapCameraPosition.automatic
    @State private var visible: MKCoordinateRegion?
    /// Longitude span seen when fully zoomed out; under 360 if the map is tall and narrow.
    @State private var fullSpan = 0.0
    @State private var checkAfterZoomOut = false
    @AppStorage("zoomedDistance") private var zoomedDistance = 30000.0

    var body: some View {
        Map(position: $camera) {
            if let location {
                Marker("Photo", coordinate: location.cl)
                    .tint(.red)
                Marker("Mirror", coordinate: location.mirror.cl)
                    .tint(.orange)
            }
            if let cluster {
                if world {
                    // A fixed-size ring: the true circle is under a pixel at this scale.
                    Annotation("", coordinate: cluster.center.cl) {
                        Circle()
                            .stroke(.blue, lineWidth: 3)
                            .frame(width: 30, height: 30)
                    }
                } else {
                    MapCircle(center: cluster.center.cl, radius: cluster.radiusKm * 1000)
                        .foregroundStyle(.blue.opacity(0.15))
                        .stroke(.blue, lineWidth: 2)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .onMapCameraChange(frequency: .onEnd) { context in
            visible = context.region
            if !world {
                zoomedDistance = context.camera.distance
            } else if checkAfterZoomOut {
                checkAfterZoomOut = false
                fullSpan = context.region.span.longitudeDelta
                if let location, !isVisible(location) {
                    zoomOut(centerLongitude: location.lon)
                }
            }
        }
        .onChange(of: world, initial: true) { moveCamera(longJump: true) }
        .onChange(of: location) { old, new in
            if let old, let new {
                moveCamera(longJump: old.km(to: new) > longJumpKm)
            } else {
                moveCamera(longJump: true)
            }
        }
    }

    private func moveCamera(longJump: Bool) {
        guard let location else { return }
        if !world {
            // Follow the photo, keeping whatever zoom the user chose.
            camera = .camera(MapCamera(centerCoordinate: location.cl, distance: zoomedDistance))
        } else if longJump || !isVisible(location) {
            // Center between the photo and its mirror if both fit, otherwise on the photo.
            let apart = min(2 * abs(location.lon), 360 - 2 * abs(location.lon))
            let between = abs(location.lon) <= 90 ? 0.0 : 180.0
            checkAfterZoomOut = true
            zoomOut(centerLongitude: apart < fullSpan * 0.9 ? between : location.lon)
        }
    }

    /// Show as much of the world as the map allows.
    private func zoomOut(centerLongitude: Double) {
        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: 170, longitudeDelta: 359)))
    }

    private func isVisible(_ point: Coord) -> Bool {
        guard let visible else { return false }
        var dLon = abs(point.lon - visible.center.longitude)
        if dLon > 180 {
            dLon = 360 - dLon
        }
        return dLon <= visible.span.longitudeDelta * 0.45
            && abs(point.lat - visible.center.latitude) <= visible.span.latitudeDelta * 0.45
    }
}
