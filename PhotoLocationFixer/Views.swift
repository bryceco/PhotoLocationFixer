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
                        if entry.location == nil {
                            Text("No location")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
            .onChange(of: library.selection) { _, selection in
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

    @State private var camera = MapCameraPosition.rect(.world)

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
        .onChange(of: world, initial: true) { updateCamera() }
        .onChange(of: location) { updateCamera() }
    }

    private func updateCamera() {
        if world {
            camera = .rect(.world)
        } else if let location {
            camera = .region(MKCoordinateRegion(center: location.cl,
                                                latitudinalMeters: 20000,
                                                longitudinalMeters: 20000))
        }
    }
}
