import SwiftUI

@main struct ARTOFFICEApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            Group { if store.active { EditorView() } else { LibraryView() } }
                .environmentObject(store)
                .tint(Color("AccentColor"))
                .onChange(of: store.project) { _, _ in store.changed() }
                .onChange(of: scenePhase) { _, value in if value == .background { store.backgrounded() } }
                .alert("ARTOFFICE", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                    Button("閉じる", role: .cancel) { store.message = nil }
                } message: { Text(store.message ?? "") }
        }
    }
}
