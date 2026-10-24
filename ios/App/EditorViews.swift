import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var deletion: Project?
    var body: some View {
        NavigationStack {
            Group {
                if store.projects.isEmpty {
                    ContentUnavailableView {
                        Label("ライブを動画にまとめよう", systemImage: "play.rectangle.on.rectangle")
                    } description: { Text("プロジェクトを作って，動画を読み込んでください。編集内容はこの端末に自動保存されます。") }
                    actions: { Button("新しいプロジェクト") { Task { await store.create() } }.buttonStyle(.borderedProminent).accessibilityIdentifier("newProject") }
                } else {
                    List(store.projects) { project in
                        Button { Task { await store.open(project) } } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "play.rectangle.fill").font(.largeTitle).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(project.name).font(.headline).foregroundStyle(.primary)
                                    Text("\(project.groups.count)組・\(Clock.text((try? Timeline(project).duration) ?? 0))").font(.subheadline).foregroundStyle(.secondary)
                                    Text(project.modifiedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.padding(.vertical, 10)
                        }
                        .contextMenu {
                            Button("複製", systemImage: "doc.on.doc") { Task { await store.duplicate(project) } }
                            Button("削除", systemImage: "trash", role: .destructive) { deletion = project }
                        }
                    }
                }
            }
            .navigationTitle("ARTOFFICE")
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Button("新規", systemImage: "plus") { Task { await store.create() } }.accessibilityIdentifier("newProjectToolbar")
            } }
            .disabled(store.busy)
            .task { await store.refresh() }
            .alert("プロジェクトを削除しますか？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                Button("削除", role: .destructive) { if let value = deletion { Task { await store.delete(value) } }; deletion = nil }
                Button("キャンセル", role: .cancel) { deletion = nil }
            } message: { Text("このプロジェクトの編集情報，アプリ内の素材，アプリ内に残した完成動画と処理済み区間を削除します。外部の素材・保存先は変更しません。") }
        }
    }
}

struct EditorView: View {
    @EnvironmentObject private var store: AppStore
    @State private var tab = 0
    var body: some View {
        NavigationStack {
            TabView(selection: $tab) {
                ImportView { id in store.project.selectedClip = id; tab = 1 }
                    .disabled(store.busy || store.exporting).tabItem { Label("動画", systemImage: "film") }.tag(0)
                TrimView().disabled(store.busy || store.exporting).tabItem { Label("編集", systemImage: "scissors") }.tag(1)
                ThumbnailView().disabled(store.busy || store.exporting).tabItem { Label("サムネイル", systemImage: "photo") }.tag(2)
                ExportView().tabItem { Label("書き出し", systemImage: "square.and.arrow.up") }.tag(3)
            }
            .navigationTitle(store.project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("一覧", systemImage: "square.grid.2x2") { Task { await store.close() } }.disabled(store.busy || store.exporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { do { try await store.flush() } catch { store.message = error.localizedDescription } } } label: {
                        Label(store.saveStatus, systemImage: store.saveStatus == "保存済み" ? "checkmark.icloud" : "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }.disabled(store.busy)
                }
            }
            .overlay { if store.busy { ProgressView(store.importStatus.isEmpty ? "処理しています" : store.importStatus).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        }
    }
}

struct ImportView: View {
    @EnvironmentObject private var store: AppStore
    var edit: (UUID) -> Void
    @State private var picker = false
    @State private var copy = true
    @State private var photos: [PhotosPickerItem] = []
    @State private var relink: UUID?
    var body: some View {
        List {
            Section("イベント") {
                TextField("イベント名", text: $store.project.name).accessibilityIdentifier("eventName")
                LabeledContent("アプリ内の素材", value: ByteCountFormatter.string(fromByteCount: store.storageBytes, countStyle: .file))
            }
            Section {
                PhotosPicker(selection: $photos, maxSelectionCount: 100, matching: .videos, preferredItemEncoding: .current) {
                    Label("写真から動画を追加", systemImage: "photo.on.rectangle.angled")
                }.frame(minHeight: 44)
                Button { relink = nil; picker = true } label: { Label("ファイルから動画を追加", systemImage: "folder") }.frame(minHeight: 44)
                Toggle("ファイルをアプリ内にコピー", isOn: $copy)
            } header: { Text("動画を読み込む") } footer: {
                Text(copy ? "素材をこの端末に保持し，次回もそのまま編集できます。素材分の空き容量が必要です。" : "ファイルを参照して重複保存を減らします。外付けドライブなどは編集・出力時にも接続が必要です。写真からの動画は常にコピーします。")
            }
            if store.project.clips.isEmpty { Section { Text("「出演順_バンド名.mp4」のファイル名なら，順番と名前を読み取ります。画面でも変更できます。").foregroundStyle(.secondary) } }
            ForEach(Array(store.project.groups.enumerated()), id: \.offset) { groupIndex, group in
                Section("\(groupIndex + 1)　\(group[0].bandName)") {
                    HStack {
                        Button("上へ", systemImage: "arrow.up") { store.project.moveGroup(groupIndex, by: -1) }.disabled(groupIndex == 0)
                        Spacer()
                        Button("下へ", systemImage: "arrow.down") { store.project.moveGroup(groupIndex, by: 1) }.disabled(groupIndex + 1 >= store.project.groups.count)
                    }.buttonStyle(.bordered).frame(minHeight: 44)
                    ForEach(group) { clip in
                        if let i = store.project.clips.firstIndex(where: { $0.id == clip.id }) {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("バンド名", text: $store.project.clips[i].bandName).font(.headline)
                                Text(clip.source.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text("\(Clock.text(clip.duration))・\(clip.source.width)×\(clip.source.height)\(clip.source.isHDR ? "・HDR→SDR" : "")\(clip.source.hasAudio ? "" : "・音声なし")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if i > 0 { Toggle("前の動画と同じバンドとして連結", isOn: $store.project.clips[i].joinPrevious) }
                                HStack {
                                    Button("カット", systemImage: "scissors") { edit(clip.id) }.buttonStyle(.bordered)
                                    Spacer()
                                    Menu {
                                        Button("素材を選び直す", systemImage: "arrow.triangle.2.circlepath") { relink = clip.id; picker = true }
                                        Button("動画を外す", systemImage: "trash", role: .destructive) { store.project.removeClip(clip.id) }
                                    } label: { Label("操作", systemImage: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.movie], allowsMultipleSelection: relink == nil) { result in
            switch result {
            case .success(let urls): Task { await store.importVideos(urls, copy: copy, relink: relink) }
            case .failure(let error): store.message = error.localizedDescription
            }
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            Task { await store.importPhotosVideos(items); photos = [] }
        }
    }
}

@MainActor final class PlaybackModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var current = 0.0
    @Published var error: String?
    private var lease: SourceLease?
    private var observer: Any?
    func load(_ clip: Clip, directory: URL) {
        stop()
        do {
            lease = try SourceLease(source: clip.source, projectDirectory: directory)
            let item = AVPlayerItem(url: lease!.url)
            let budget = DeviceBudget.current()
            item.preferredForwardBufferDuration = 2
            item.preferredMaximumResolution = CGSize(width: budget.previewHeight * 16 / 9, height: budget.previewHeight)
            let player = AVPlayer(playerItem: item); self.player = player
            player.seek(to: CMTime(ticks: clip.start), toleranceBefore: .zero, toleranceAfter: .zero)
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] value in
                guard value.isNumeric else { return }; self?.current = value.seconds
            }
        } catch { self.error = error.localizedDescription }
    }
    func seek(_ seconds: Double) { player?.pause(); player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: Clock.scale), toleranceBefore: .zero, toleranceAfter: .zero); current = max(0, seconds) }
    func step(_ frames: Int) { player?.pause(); player?.currentItem?.step(byCount: frames) }
    func stop() { player?.pause(); if let observer { player?.removeTimeObserver(observer) }; observer = nil; player = nil; lease = nil }
}

struct TrimView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        GeometryReader { proxy in
            if store.project.clips.isEmpty { ContentUnavailableView("動画を追加してください", systemImage: "film") }
            else if proxy.size.width >= 800 {
                HStack(spacing: 0) {
                    List(store.project.clips) { clip in
                        Button { store.project.selectedClip = clip.id } label: {
                            VStack(alignment: .leading) { Text(clip.bandName); Text(Clock.text(clip.duration)).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 8)
                        }.listRowBackground(store.project.selectedClip == clip.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    }.frame(width: 270)
                    Divider()
                    if let id = store.project.selectedClip ?? store.project.clips.first?.id { ClipEditor(id: id).id(id) }
                }
            } else {
                VStack(spacing: 0) {
                    Picker("編集する動画", selection: Binding(get: { store.project.selectedClip ?? store.project.clips[0].id }, set: { store.project.selectedClip = $0 })) {
                        ForEach(store.project.clips) { clip in Text(clip.bandName).tag(clip.id) }
                    }.pickerStyle(.menu).frame(minHeight: 48)
                    if let id = store.project.selectedClip ?? store.project.clips.first?.id { ClipEditor(id: id).id(id) }
                }
            }
        }
    }
}

struct ClipEditor: View {
    @EnvironmentObject private var store: AppStore
    let id: UUID
    @StateObject private var playback = PlaybackModel()
    @State private var startText = ""
    @State private var endText = ""
    var index: Int? { store.project.clips.firstIndex { $0.id == id } }
    var body: some View {
        if let i = index {
            let clip = store.project.clips[i]
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VideoPlayer(player: playback.player).aspectRatio(16 / 9, contentMode: .fit).background(.black).clipShape(RoundedRectangle(cornerRadius: 12))
                    if let error = playback.error { Text(error).foregroundStyle(.red) }
                    Text(Clock.text(Clock.ticks(playback.current), precise: true)).font(.title3.monospacedDigit()).frame(maxWidth: .infinity)
                    Slider(value: Binding(get: { min(Clock.seconds(clip.source.duration), playback.current) }, set: { playback.seek($0) }), in: 0...max(0.01, Clock.seconds(clip.source.duration)))
                        .accessibilityLabel("動画の再生位置")
                    HStack {
                        Button("1フレーム戻る", systemImage: "backward.end") { playback.step(-1) }.labelStyle(.iconOnly)
                        Spacer(); Button("再生", systemImage: "play.fill") { playback.player?.play() }
                        Button("停止", systemImage: "pause.fill") { playback.player?.pause() }; Spacer()
                        Button("1フレーム進む", systemImage: "forward.end") { playback.step(1) }.labelStyle(.iconOnly)
                    }.buttonStyle(.bordered).controlSize(.large)
                    GroupBox("開始位置") {
                        VStack {
                            Slider(value: Binding(get: { Clock.seconds(clip.start) }, set: { store.project.clips[i].trimStart(Clock.ticks($0)); playback.seek(Clock.seconds(store.project.clips[i].start)) }), in: 0...max(0.01, Clock.seconds(clip.source.duration)))
                            HStack {
                                Button("現在位置を設定") { store.project.clips[i].trimStart(Clock.ticks(playback.current)) }
                                Spacer(); Button("開始へ") { playback.seek(Clock.seconds(clip.start)) }
                            }.buttonStyle(.bordered).frame(minHeight: 44)
                            TextField("0:00:00.000", text: $startText).textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                                .onSubmit { if let value = parseTime(startText) { store.project.clips[i].trimStart(value) } else { store.message = "時刻は0:00:00.000の形式で入力してください。" }; syncText() }
                        }
                    }
                    GroupBox("終了位置") {
                        VStack {
                            Slider(value: Binding(get: { Clock.seconds(clip.end) }, set: { store.project.clips[i].trimEnd(Clock.ticks($0)); playback.seek(Clock.seconds(store.project.clips[i].end)) }), in: 0...max(0.01, Clock.seconds(clip.source.duration)))
                            HStack {
                                Button("現在位置を設定") { store.project.clips[i].trimEnd(Clock.ticks(playback.current)) }
                                Spacer(); Button("終了前を確認") { playback.seek(max(Clock.seconds(clip.start), Clock.seconds(clip.end) - 3)); playback.player?.play() }
                            }.buttonStyle(.bordered).frame(minHeight: 44)
                            TextField("0:00:00.000", text: $endText).textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                                .onSubmit { if let value = parseTime(endText) { store.project.clips[i].trimEnd(value) } else { store.message = "時刻は0:00:00.000の形式で入力してください。" }; syncText() }
                        }
                    }
                    Text("残す長さ　\(Clock.text(clip.duration, precise: true))").font(.headline)
                }.padding().frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }
            .onAppear { playback.load(clip, directory: store.directory); syncText() }
            .onDisappear { playback.stop() }
            .onChange(of: clip.start) { _, _ in syncText() }
            .onChange(of: clip.end) { _, _ in syncText() }
        }
    }
    func syncText() { if let i = index { startText = Clock.text(store.project.clips[i].start, precise: true); endText = Clock.text(store.project.clips[i].end, precise: true) } }
    func parseTime(_ text: String) -> Int64? {
        let parts = text.split(separator: ":")
        guard parts.count == 3, let hours = Int(parts[0]), let minutes = Int(parts[1]), let seconds = Double(parts[2]),
              hours >= 0, hours < 100_000, (0..<60).contains(minutes), seconds.isFinite, (0..<60).contains(seconds) else { return nil }
        return Clock.ticks(Double(hours * 3600 + minutes * 60) + seconds)
    }
}
