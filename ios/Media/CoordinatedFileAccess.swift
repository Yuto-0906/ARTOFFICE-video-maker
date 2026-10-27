import Foundation
import UniformTypeIdentifiers

enum CoordinatedFileAccess {
    static func read<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { value in
            result = Result { try body(value) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw AppError.message("ファイルを取得できません。クラウドの接続状態を確認してください。") }
        return try result.get()
    }
    static func prepare(_ url: URL) throws -> URL { try read(url) { $0 } }
}

enum FolderVideoImport {
    static func scan(_ folder: URL) throws -> [URL] {
        try CoordinatedFileAccess.read(folder) { directory in
            var failure: Error?
            guard let iterator = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in failure = error; return false }) else {
                throw AppError.message("フォルダーを開けません。この提供元でフォルダー選択が使えない場合は，複数の動画を選択してください。")
            }
            var videos: [URL] = []
            for case let file as URL in iterator {
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                guard values.isRegularFile == true, let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .movie) else { continue }
                videos.append(file)
            }
            if let failure { throw failure }
            guard !videos.isEmpty else { throw AppError.message("選択したフォルダーに動画がありません。Box・Google Driveの場合は「ファイル」で接続を確認してください。") }
            return videos.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }
}
