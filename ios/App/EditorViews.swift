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
                        .accessibilityIdentifier("project-" + project.id.uuidString)
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
    @State private var storage = false
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
                    HStack(spacing: 14) {
                        Button("容量", systemImage: "internaldrive") { storage = true }.labelStyle(.titleAndIcon).disabled(store.busy || store.exporting)
                        VStack(spacing: 1) {
                            Button("保存", systemImage: "square.and.arrow.down") { Task { await store.saveNow() } }
                                .labelStyle(.titleAndIcon).disabled(store.busy).accessibilityIdentifier("saveProject")
                            Text(store.saveStatus == "保存済み" ? (store.saveFeedback ?? "自動保存済み") : store.saveStatus).font(.caption2)
                                .foregroundStyle(.secondary).accessibilityIdentifier("saveStatus")
                        }
                    }
                }
            }
            .overlay { if store.busy { ProgressView(store.importStatus.isEmpty ? "処理しています" : store.importStatus).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .overlay(alignment: .top) {
                if store.showingSaveToast, let feedback = store.saveFeedback { Label(feedback, systemImage: "checkmark.circle.fill").font(.subheadline).padding(10).background(.regularMaterial, in: Capsule()).padding(.top, 8).allowsHitTesting(false).accessibilityHidden(true) }
            }
            .sheet(isPresented: $storage) { StorageOverview() }
        }
    }
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
                            VStack(alignment: .leading) { Text(clip.displayTitle); Text(Clock.text(clip.duration)).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 8)
                        }.listRowBackground(store.project.selectedClip == clip.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    }.frame(width: 270)
                    Divider()
                    if let id = store.project.selectedClip ?? store.project.clips.first?.id { ClipEditor(id: id).id(id) }
                }
            } else {
                VStack(spacing: 0) {
                    Picker("編集する動画", selection: Binding(get: { store.project.selectedClip ?? store.project.clips[0].id }, set: { store.project.selectedClip = $0 })) {
                        ForEach(store.project.clips) { clip in Text(clip.displayTitle).tag(clip.id) }
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
    var organizing = false
    @StateObject private var playback = PlaybackModel()
    @State private var namingExpanded = false
    @State private var startText = ""
    @State private var endText = ""
    @Environment(\.scenePhase) private var scenePhase
    var index: Int? { store.project.clips.firstIndex { $0.id == id } }
    var body: some View {
        if let i = index {
            let clip = store.project.clips[i]
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack {
                        EmbeddedMoviePlayer(player: playback.player)
                        if playback.loading { ProgressView("動画を開いています").tint(.white).foregroundStyle(.white) }
                    }.aspectRatio(16 / 9, contentMode: .fit).background(.black).clipShape(RoundedRectangle(cornerRadius: 12))
                    if let error = playback.error { Text(error).foregroundStyle(.red) }
                    Text(Clock.text(Clock.ticks(playback.current), precise: true)).font(.title3.monospacedDigit()).frame(maxWidth: .infinity)
                    Slider(value: Binding(get: { min(Clock.seconds(clip.source.duration), playback.current) }, set: { playback.seek($0) }), in: 0...max(0.01, Clock.seconds(clip.source.duration)))
                        .accessibilityLabel("動画の再生位置")
                    HStack {
                        Button("1フレーム戻る", systemImage: "backward.end") { playback.step(-1) }.labelStyle(.iconOnly)
                        Spacer()
                        Button(playback.isPlaying ? "一時停止" : "再生", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") { playback.toggle() }
                            .frame(minWidth: 100, minHeight: 44).accessibilityIdentifier("togglePlayback").disabled(playback.player == nil)
                        Spacer()
                        Button("1フレーム進む", systemImage: "forward.end") { playback.step(1) }.labelStyle(.iconOnly)
                    }.buttonStyle(.bordered).controlSize(.large)
                    DisclosureGroup("名前と並び順", isExpanded: $namingExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("一覧で使う動画名").font(.caption).foregroundStyle(.secondary)
                            TextField("動画の表示名", text: Binding(get: { store.project.clips[i].displayName ?? (clip.source.fileName as NSString).deletingPathExtension }, set: { store.project.clips[i].displayName = $0 }))
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("clipDisplayName")
                            Text("元のファイル：\(clip.source.fileName)").font(.caption).foregroundStyle(.secondary)
                            if !clip.joinPrevious {
                                Text("映像に表示するバンド名").font(.caption).foregroundStyle(.secondary)
                                TextField("動画に表示するバンド名", text: $store.project.clips[i].bandName).textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("clipBandName")
                                Button("表示名をバンド名にも使う") {
                                    store.project.clips[i].bandName = Naming.parse(clip.displayTitle + ".mp4")?.band ?? clip.displayTitle
                                }.buttonStyle(.bordered)
                            } else { Text("バンド名は連結した動画の先頭で変更できます。").font(.caption).foregroundStyle(.secondary) }
                            if let group = store.project.groups.firstIndex(where: { $0.contains(where: { $0.id == id }) }) {
                                HStack {
                                    Text("出演順 \(group + 1) / \(store.project.groups.count)")
                                    Spacer()
                                    Button("前へ", systemImage: "arrow.up") { store.project.moveGroup(group, by: -1) }.disabled(group == 0)
                                    Button("後へ", systemImage: "arrow.down") { store.project.moveGroup(group, by: 1) }.disabled(group + 1 == store.project.groups.count)
                                }.buttonStyle(.bordered).frame(minHeight: 44)
                            }
                            Text("表示名とバンド名はこのプロジェクト内の名前です。元の動画やクラウド上のファイル名は変更しません。").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 44).onAppear { namingExpanded = organizing }
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
                                Spacer(); Button("終了前を確認") { playback.seek(max(Clock.seconds(clip.start), Clock.seconds(clip.end) - 3)); playback.play() }
                            }.buttonStyle(.bordered).frame(minHeight: 44)
                            TextField("0:00:00.000", text: $endText).textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                                .onSubmit { if let value = parseTime(endText) { store.project.clips[i].trimEnd(value) } else { store.message = "時刻は0:00:00.000の形式で入力してください。" }; syncText() }
                        }
                    }
                    Text("残す長さ　\(Clock.text(clip.duration, precise: true))").font(.headline)
                }.padding().frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }
            .task(id: clip.source) { syncText(); await playback.load(clip, directory: store.directory) }
            .onDisappear { playback.stop() }
            .onChange(of: clip.start) { _, _ in syncText(); playback.updateRange(clip) }
            .onChange(of: clip.end) { _, _ in syncText(); playback.updateRange(clip) }
            .onChange(of: scenePhase) { _, phase in if phase != .active { playback.pause() } }
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
