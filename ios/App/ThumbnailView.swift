import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct ThumbnailCropCanvas: View {
    let image: UIImage
    @Binding var crop: PhotoCrop
    @State private var gestureStart: PhotoCrop?
    @GestureState private var gestureActive = false
    var body: some View {
        GeometryReader { proxy in
            let width = Double(image.size.width), height = Double(image.size.height)
            let rect = crop.rect(width: width, height: height), scale = Double(proxy.size.width) / rect.width
            ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: image).resizable().frame(width: width * scale, height: height * scale)
                    .offset(x: -rect.x * scale, y: -rect.y * scale)
                Path { path in
                    for fraction in [1.0 / 3, 2.0 / 3] {
                        let x = proxy.size.width * fraction, y = proxy.size.height * fraction
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                }.stroke(.white.opacity(0.45), lineWidth: 1).allowsHitTesting(false)
            }.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading).clipped().contentShape(Rectangle())
                .highPriorityGesture(SimultaneousGesture(DragGesture(minimumDistance: 2), MagnifyGesture())
                .updating($gestureActive) { _, active, _ in active = true }.onChanged { value in
                    if gestureStart == nil { gestureStart = crop.normalized(width: width, height: height) }
                    guard let origin = gestureStart else { return }
                    let anchor = value.second?.startAnchor ?? .center
                    let magnification = Double(value.second?.magnification ?? 1)
                    let translation = value.first?.translation ?? .zero
                    crop = origin.zoomed(to: origin.zoom * magnification, width: width, height: height,
                        anchorX: Double(anchor.x), anchorY: Double(anchor.y))
                        .dragged(x: Double(translation.width), y: Double(translation.height), viewportWidth: Double(proxy.size.width), width: width, height: height)
                }.onEnded { _ in gestureStart = nil })
                .onChange(of: gestureActive) { _, active in if !active { gestureStart = nil } }
        }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.8), lineWidth: 1))
            .accessibilityLabel("16対9の切抜き枠。写真をドラッグし，ピンチで拡大します")
    }
}

struct ThumbnailView: View {
    @EnvironmentObject private var store: AppStore
    @State private var picker = false
    @State private var photos: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var loading = false
    @State private var sharing = false
    @State private var shareURL: URL?
    @State private var preparingShare = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("集合写真を16:9に切り抜く").font(.title2.bold())
                Text("枠の中の写真を直接ドラッグしてください。指を広げると，その位置を中心に拡大できます。").foregroundStyle(.secondary)
                HStack {
                    PhotosPicker(selection: $photos, matching: .images, preferredItemEncoding: .current) { Label("写真から選ぶ", systemImage: "photo") }
                    Button("ファイルから選ぶ", systemImage: "folder") { picker = true }
                }.buttonStyle(.bordered).controlSize(.large)
                if let image, let crop = store.project.thumbnail {
                    ThumbnailCropCanvas(image: image, crop: Binding(get: { store.project.thumbnail ?? crop }, set: { store.project.thumbnail = $0 }))
                        .accessibilityIdentifier("thumbnailCropCanvas")
                    HStack {
                        Text("拡大 \(Int(crop.zoom * 100))%").font(.headline.monospacedDigit())
                        Spacer()
                        Button("位置と拡大をリセット", systemImage: "arrow.counterclockwise") {
                            var reset = crop; reset.zoom = 1; reset.centerX = 0.5; reset.centerY = 0.5
                            store.project.thumbnail = reset
                        }.frame(minHeight: 44)
                    }
                    Slider(value: Binding(get: { store.project.thumbnail?.zoom ?? 1 }, set: { value in
                        if let current = store.project.thumbnail { store.project.thumbnail = current.zoomed(to: value, width: image.size.width, height: image.size.height) }
                    }), in: 1...5).accessibilityLabel("写真の拡大率")
                    Text("100%は写真が枠を満たす最小サイズです。余白のない方向には動きません。表示している範囲がそのままJPEGになります。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { Task { await shareThumbnail() } } label: {
                        Label(preparingShare ? "JPEGを準備しています" : "サムネイルを保存・共有", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).disabled(preparingShare)
                    Text("切抜き位置は自動保存され，動画の書き出しにも使われます。サムネイルだけを保存することもできます。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("この写真を使わない", role: .destructive) { store.project.thumbnail = nil; self.image = nil }.frame(minHeight: 44)
                } else if loading { ProgressView("写真を読み込んでいます").frame(maxWidth: .infinity, minHeight: 180) }
                else { ContentUnavailableView("写真を選択してください", systemImage: "photo") }
            }.padding().frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .task(id: store.project.thumbnail?.relativePath) {
            image = nil
            guard let crop = store.project.thumbnail else { return }
            loading = true; defer { loading = false }
            let url = store.directory.appendingPathComponent(crop.relativePath)
            do {
                let decoded = try await Task.detached { try MediaFiles.photo(url) }.value
                try Task.checkCancellation(); image = decoded
            } catch is CancellationError {} catch { store.message = error.localizedDescription }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result { case .success(let urls): if let url = urls.first { Task { await store.importPhoto(url) } }
            case .failure(let error): store.message = error.localizedDescription }
        }
        .sheet(isPresented: $sharing, onDismiss: { if let shareURL { try? FileManager.default.removeItem(at: shareURL) }; shareURL = nil }) {
            if let shareURL { ShareSheet(urls: [shareURL]) }
        }
        .onChange(of: photos) { _, item in
            guard let item else { return }
            Task {
                do {
                    if let photo = try await item.loadTransferable(type: PickedPhoto.self) {
                        await store.importPhoto(photo.url); try? FileManager.default.removeItem(at: photo.url.deletingLastPathComponent())
                    }
                } catch { store.message = error.localizedDescription }
                photos = nil
            }
        }
    }
    private func shareThumbnail() async {
        guard let crop = store.project.thumbnail else { return }
        preparingShare = true; defer { preparingShare = false }
        do {
            try await store.flush()
            let directory = store.directory
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ARTOFFICEThumbnailShare")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for old in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
                if let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < Date().addingTimeInterval(-86400) { try? FileManager.default.removeItem(at: old) }
            }
            let output = root.appendingPathComponent("thumbnail-\(UUID().uuidString).jpg")
            try await Task.detached { try MediaFiles.exportPhoto(crop, directory: directory, output: output) }.value
            shareURL = output; sharing = true
        } catch { store.message = error.localizedDescription }
    }
}
