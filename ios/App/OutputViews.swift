import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ThumbnailView: View {
    @EnvironmentObject private var store: AppStore
    @State private var picker = false
    @State private var photos: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var dragOrigin: (Double, Double)?
    @State private var zoomOrigin: Double?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("集合写真を16:9に切り抜く").font(.title2.bold())
                Text("ドラッグで位置を動かし，ピンチかスライダーで拡大できます。サムネイルは省略できます。").foregroundStyle(.secondary)
                HStack {
                    PhotosPicker(selection: $photos, matching: .images, preferredItemEncoding: .current) { Label("写真から", systemImage: "photo") }
                    Button("ファイルから", systemImage: "folder") { picker = true }
                }.buttonStyle(.bordered).controlSize(.large)
                if let image, let crop = store.project.thumbnail {
                    GeometryReader { proxy in
                        let rect = crop.rect(width: image.size.width, height: image.size.height)
                        let scale = proxy.size.width / rect.width
                        Image(uiImage: image).resizable()
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .position(x: image.size.width * scale / 2 - rect.x * scale, y: image.size.height * scale / 2 - rect.y * scale)
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped().contentShape(Rectangle())
                            .gesture(DragGesture().onChanged { value in
                                if dragOrigin == nil { dragOrigin = (crop.centerX, crop.centerY) }
                                store.project.thumbnail?.centerX = min(1, max(0, dragOrigin!.0 - value.translation.width / (image.size.width * scale)))
                                store.project.thumbnail?.centerY = min(1, max(0, dragOrigin!.1 - value.translation.height / (image.size.height * scale)))
                            }.onEnded { _ in dragOrigin = nil })
                            .simultaneousGesture(MagnificationGesture().onChanged { value in
                                if zoomOrigin == nil { zoomOrigin = crop.zoom }
                                store.project.thumbnail?.zoom = min(5, max(1, zoomOrigin! * value))
                            }.onEnded { _ in zoomOrigin = nil })
                    }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("拡大率").font(.headline)
                    Slider(value: Binding(get: { store.project.thumbnail?.zoom ?? 1 }, set: { store.project.thumbnail?.zoom = $0 }), in: 1...5)
                    Text("左右の位置").font(.subheadline)
                    Slider(value: Binding(get: { store.project.thumbnail?.centerX ?? 0.5 }, set: { store.project.thumbnail?.centerX = $0 }), in: 0...1)
                    Text("上下の位置").font(.subheadline)
                    Slider(value: Binding(get: { store.project.thumbnail?.centerY ?? 0.5 }, set: { store.project.thumbnail?.centerY = $0 }), in: 0...1)
                    HStack {
                        Button("位置をリセット") { store.project.thumbnail?.zoom = 1; store.project.thumbnail?.centerX = 0.5; store.project.thumbnail?.centerY = 0.5 }
                        Spacer(); Button("写真を外す", role: .destructive) { store.project.thumbnail = nil; self.image = nil }
                    }.buttonStyle(.bordered).controlSize(.large)
                } else { ContentUnavailableView("写真を選択してください", systemImage: "photo") }
            }.padding().frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .task(id: store.project.thumbnail?.relativePath) {
            if let crop = store.project.thumbnail { image = try? MediaFiles.photo(store.directory.appendingPathComponent(crop.relativePath)) }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result { case .success(let urls): if let url = urls.first { Task { await store.importPhoto(url) } }
            case .failure(let error): store.message = error.localizedDescription }
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
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ExportView: View {
    @EnvironmentObject private var store: AppStore
    @State private var folderPicker = false
    @State private var destination: URL?
    @State private var destinationBookmark: Data?
    @State private var sharing = false
    @State private var shareURLs: [URL] = []
    @State private var cleanup = false
    @State private var cleanCompleted = false
    @State private var preview = false
    var body: some View {
        Form {
            Section("画質") {
                Picker("解像度", selection: $store.project.resolution) { ForEach(Resolution.allCases) { Text($0.rawValue).tag($0) } }
                Picker("フレームレート", selection: $store.project.frameRate) { ForEach(FrameRate.allCases) { Text($0.rawValue + " fps").tag($0) } }
                Text("素材に合うフレームレートを選ぶと，不要なフレームの生成を避けられます。完成動画は選択した設定で出力します。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(store.exporting || store.busy)
            Section("保存先") {
                LabeledContent("出力先", value: destination?.lastPathComponent ?? "アプリ内")
                Button("ファイルのフォルダーを選択", systemImage: "folder") { folderPicker = true }
                if destination != nil { Button("アプリ内に戻す") { destination = nil; destinationBookmark = nil; store.project.destinationBookmark = nil } }
                Text("外部の保存先を選ぶと，アプリ内に完成動画を重複して作りません。処理済み区間は復旧のため端末内に保持します。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(store.exporting || store.busy)
            if let timeline = store.timeline {
                let capacity = CapacityEstimate(duration: timeline.duration, resolution: store.project.resolution, separateDestination: destination != nil)
                Section("確認") {
                    Button("仕上がりを確認", systemImage: "play.rectangle") { preview = true }
                        .disabled(store.exporting || store.busy || store.project.clips.isEmpty)
                    LabeledContent("動画の長さ", value: Clock.text(timeline.duration))
                    LabeledContent("バンド数", value: "\(store.project.groups.count)組")
                    LabeledContent("完成動画の目安", value: bytes(capacity.output))
                    LabeledContent("端末内の作業容量の目安", value: bytes(capacity.localWorking))
                    if destination != nil { LabeledContent("保存先に必要な容量の目安", value: bytes(capacity.destinationWorking)) }
                    Text("作業容量には処理済み区間と完成動画の同時保存を含みます。保存先が端末内の同じディスクなら，両方の空き容量が必要です。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("チャプター") {
                    Text(timeline.chapters.isEmpty ? "動画を追加してください。" : timeline.chapters).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("チャプターをコピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = timeline.chapters }
                    ForEach(timeline.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
            } else {
                Section { Text((try? invalidReason()) ?? "動画を追加してください。").foregroundStyle(.orange) }
            }
            if !store.exportedFiles.isEmpty {
                Section("完成ファイル") {
                    ForEach(store.exportedFiles.filter { $0.pathExtension != "json" }, id: \.path) { url in
                        Button(url.lastPathComponent, systemImage: url.pathExtension == "mp4" ? "play.rectangle" : "doc") { shareURLs = [url]; sharing = true }.frame(minHeight: 44)
                    }
                    Button("完成ファイルをまとめて共有") { shareURLs = store.exportedFiles.filter { $0.pathExtension != "json" }; sharing = true }
                }
            }
            Section("容量と診断") {
                Button("処理済み区間を削除", role: .destructive) { cleanCompleted = false; cleanup = true }.disabled(store.exporting || store.busy)
                Button("アプリ内の完成ファイルを削除", role: .destructive) { cleanCompleted = true; cleanup = true }.disabled(store.exporting || store.busy)
                if let report = store.diagnosticFile {
                    Button("直近の診断レポートを共有") { shareURLs = [report]; sharing = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            exportControls.padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
        }
        .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            do {
                if let url = try result.get().first {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    destinationBookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    store.project.destinationBookmark = destinationBookmark
                    destination = url
                }
            } catch { store.message = error.localizedDescription }
        }
        .sheet(isPresented: $sharing) { ShareSheet(urls: shareURLs) }
        .sheet(isPresented: $preview) { TimelinePreview(project: store.project, directory: store.directory) }
        .onAppear {
            destinationBookmark = store.project.destinationBookmark
            do { destination = try resolveDestination() }
            catch { store.message = "保存先のフォルダーを選び直してください。" }
        }
        .alert(cleanCompleted ? "アプリ内の完成ファイルを削除しますか？" : "処理済み区間を削除しますか？", isPresented: $cleanup) {
            Button("削除", role: .destructive) {
                Task { if cleanCompleted { await store.clearCompletedFiles() } else { await store.clearExportCache() } }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(cleanCompleted
                ? "このプロジェクトのアプリ内にある完成動画・チャプター・サムネイルを削除します。外部へ保存したコピーを確認してから実行してください。編集情報・素材・処理済み区間と外部の保存先は残ります。"
                : "編集情報と完成ファイルは残ります。次回の出力では全区間を処理し直します。")
        }
    }
    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.exporting {
                ProgressView(value: store.progress)
                Text(store.exportStatus).font(.subheadline)
                Text("アプリを開いたままお待ちください。ほかのアプリへ移動すると中断し，完了した区間から次回にやり直せます。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("中断する", role: .destructive) { store.cancelExport() }.frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Button {
                    do { store.startExport(destination: try resolveDestination()) }
                    catch { store.message = "保存先へ再アクセスできません。フォルダーを選び直してください。" }
                } label: { Label("書き出しを開始", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.borderedProminent).disabled(store.project.clips.isEmpty || store.timeline == nil || store.busy)
                    .accessibilityIdentifier("startExport")
                if !store.exportStatus.isEmpty { Text(store.exportStatus).font(.subheadline) }
            }
        }
    }
    func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    func invalidReason() throws -> String { do { _ = try Timeline(store.project); return "動画を追加してください。" } catch { return error.localizedDescription } }
    func resolveDestination() throws -> URL? {
        guard let destinationBookmark else { return nil }
        var stale = false
        return try URL(resolvingBookmarkData: destinationBookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
    }
}
