import Foundation

/// Serializes every save. Autosave never copies or hashes media.
actor ProjectRepository {
    let root: URL
    private var savedRevisions: [UUID: Int] = [:]
    init(root: URL) { self.root = root }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func save(_ project: Project, revision: Int? = nil) throws {
        try Task.checkCancellation()
        if let revision, let saved = savedRevisions[project.id], revision < saved { return }
        try project.validate()
        let directory = directory(project.id), file = directory.appendingPathComponent("project.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        // Retain only a validated previous generation，never overwrite it with a corrupt primary.
        if let old = try? Data(contentsOf: file), let previous = try? JSONDecoder().decode(Project.self, from: old),
           (try? previous.validate()) != nil {
            try old.write(to: directory.appendingPathComponent("previous.json"), options: .atomic)
        }
        try data.write(to: file, options: .atomic)
        if let revision { savedRevisions[project.id] = revision }
    }
    func load(_ id: UUID) throws -> (project: Project, recovered: Bool) {
        let directory = directory(id)
        var lastError: Error = AppError.message("保存データが見つかりません。")
        for (name, recovered) in [("project.json", false), ("previous.json", true)] {
            do {
                let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
                try project.validate()
                guard project.id == id else { throw AppError.message("保存データの識別情報が一致しません。") }
                return (project, recovered)
            } catch { lastError = error }
        }
        throw lastError
    }
    func list() -> [Project] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return try? load(id).project
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }
    func duplicate(_ original: Project) throws -> Project {
        var copy = original; copy.id = UUID(); copy.name += " のコピー"; copy.modifiedAt = Date()
        let from = directory(original.id), to = directory(copy.id)
        try FileManager.default.createDirectory(at: to.appendingPathComponent("Media"), withIntermediateDirectories: true)
        do {
            let media = Set(original.clips.compactMap(\.source.relativePath) + [original.thumbnail?.relativePath].compactMap { $0 })
            for path in media {
                let src = from.appendingPathComponent(path), dest = to.appendingPathComponent(path)
                // Managed media is immutable. Linking avoids copying hours of footage when
                // duplicating a project; unlinking either project preserves the other copy.
                do { try FileManager.default.linkItem(at: src, to: dest) }
                catch { try FileManager.default.copyItem(at: src, to: dest) }
            }
            try save(copy); return copy
        } catch { try? FileManager.default.removeItem(at: to); throw error }
    }
    func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: directory(id)) }
    func allocatedBytes(_ id: UUID) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory(id), includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        return enumerator.reduce(Int64(0)) { total, item in
            guard let url = item as? URL else { return total }
            return total + Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
    }
}
