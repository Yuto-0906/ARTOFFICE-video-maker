import Foundation

/// Reuse is confined to this project's managed job directories. Linking retains
/// immutable media without copying a five-hour set of chunks into another job.
enum ChunkReuse {
    struct Candidate { var url: URL; var receipt: ChunkReceipt }

    static func candidates(projectDirectory: URL, excluding job: URL) -> [String: [Candidate]] {
        let fm = FileManager.default
        let base = projectDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard let jobs = try? fm.contentsOfDirectory(at: projectDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else { return [:] }
        var result: [String: [Candidate]] = [:]
        for directory in jobs where directory != job && directory.lastPathComponent.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil {
            let expected = base + "/" + directory.lastPathComponent
            guard directory.resolvingSymlinksInPath().standardizedFileURL.path == expected,
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let journalURL = directory.appendingPathComponent("journal.json")
            guard journalURL.resolvingSymlinksInPath().standardizedFileURL.path == expected + "/journal.json",
                  let size = try? journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_000_000,
                  let data = try? Data(contentsOf: journalURL),
                  let journal = try? JSONDecoder().decode(ExportJournal.self, from: data), journal.rendererVersion == ExportEngine.rendererVersion else { continue }
            for (index, receipt) in journal.completed {
                guard index == String(receipt.range.index), receipt.range.index >= 0,
                      let key = receipt.contentKey, key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { continue }
                let url = ExportEngine.chunkURL(receipt.range, job: directory)
                guard url.resolvingSymlinksInPath().standardizedFileURL.path == expected + "/" + url.lastPathComponent else { continue }
                result[key, default: []].append(Candidate(url: url, receipt: receipt))
            }
        }
        return result
    }

    static func link(_ candidates: [Candidate], to output: URL, chunk: ExportChunk, project: Project, control: ExportControl) async throws -> ChunkReceipt? {
        for candidate in candidates {
            try control.check()
            guard try await ExportEngine.reusable(candidate.url, receipt: candidate.receipt, chunk: chunk, project: project) else { continue }
            // A cache miss (including unsupported hard links) falls back to encoding.
            // Never modify the linked inode in place；new output uses a partial file.
            try? FileManager.default.removeItem(at: output)
            do { try FileManager.default.linkItem(at: candidate.url, to: output) } catch { continue }
            let values = try output.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return ChunkReceipt(byteCount: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate,
                range: chunk, contentKey: candidate.receipt.contentKey)
        }
        return nil
    }
}
