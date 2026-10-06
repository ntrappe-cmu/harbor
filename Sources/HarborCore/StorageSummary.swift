import Foundation

public struct StorageSummary: Sendable {
    public var bytes: [String: Int64] = [:]
    public var total: Int64 { bytes.values.reduce(0, +) }
    public var count = 0
    public var partial = false
    public static let categories = ["Code", "Images", "Media", "Documents", "Other"]
    public static func scan(_ root: URL) throws -> StorageSummary {
        var result = StorageSummary()
        var failure: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey], errorHandler: { _, error in failure = error; return false }) else {
            throw WorkspaceError.invalid("The working folder could not be measured.")
        }
        var entries = 0
        for case let file as URL in iterator {
            try Task.checkCancellation()
            entries += 1
            if entries > 100_000 { result.partial = true; break }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let ext = file.pathExtension.lowercased()
            let category: String
            if ["swift", "js", "ts", "tsx", "jsx", "html", "css", "py", "json", "c", "cpp", "h", "rs", "go", "yaml", "yml", "sh"].contains(ext) { category = "Code" }
            else if ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "avif", "ico"].contains(ext) { category = "Images" }
            else if ["mp4", "mov", "mp3", "wav", "m4a", "webm"].contains(ext) { category = "Media" }
            else if ["pdf", "md", "txt", "docx", "csv", "pptx", "xlsx"].contains(ext) { category = "Documents" }
            else { category = "Other" }
            result.bytes[category, default: 0] += Int64(values.fileSize ?? 0)
            result.count += 1
        }
        if let failure { throw failure }
        return result
    }
}
