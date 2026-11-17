import Foundation
import UniformTypeIdentifiers

/// 文件的粗粒度视觉分类。
enum FileCategory: Sendable {
    case folder
    case image
    case video
    case audio
    case document
    case archive
    case code
    case application
    case other

    var sfSymbolName: String {
        switch self {
        case .folder: "folder.fill"
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .document: "doc.text"
        case .archive: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .application: "app"
        case .other: "doc"
        }
    }
}

/// 不访问文件内容的轻量文件类型判断。
enum FileIconHelper {
    private static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg"]
    private static let videos: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
    private static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg"]
    private static let documents: Set<String> = ["txt", "md", "rtf", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key"]
    private static let archives: Set<String> = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg"]
    private static let code: Set<String> = ["swift", "m", "mm", "h", "c", "cc", "cpp", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "html", "css", "json", "yaml", "yml", "toml", "sh"]

    static func category(for url: URL, isDirectory: Bool) -> FileCategory {
        if isDirectory { return .folder }
        if url.pathExtension.lowercased() == "app" { return .application }

        let ext = url.pathExtension.lowercased()
        if images.contains(ext) { return .image }
        if videos.contains(ext) { return .video }
        if audio.contains(ext) { return .audio }
        if documents.contains(ext) { return .document }
        if archives.contains(ext) { return .archive }
        if code.contains(ext) { return .code }
        return .other
    }

    /// 扩展名 → 类型描述的缓存。
    /// `UTType(filenameExtension:)` 每次都要查系统类型数据库，一个大目录里扩展名高度重复，
    /// 逐个查询会成为目录读取的主要开销（实测 4000 个文件约 100 ms）。
    private static let typeNameCache = NSCache<NSString, NSString>()

    static func localizedType(extension ext: String) -> String {
        guard !ext.isEmpty else { return "文件" }

        let key = ext as NSString
        if let cached = typeNameCache.object(forKey: key) {
            return cached as String
        }

        let name: String
        if let description = UTType(filenameExtension: ext)?.localizedDescription,
           !description.isEmpty {
            name = description
        } else {
            name = "\(ext.uppercased()) 文件"
        }
        typeNameCache.setObject(name as NSString, forKey: key)
        return name
    }
}
