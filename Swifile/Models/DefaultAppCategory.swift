import UniformTypeIdentifiers

// MARK: - 默认应用类别

/// 可以单独指定默认应用的常见文件类别。
/// 匹配文件用 UTType 一致性判断；查询候选应用时用一个代表性扩展名向系统要推荐列表。
enum DefaultAppCategory: String, CaseIterable, Identifiable {
    case image
    case video
    case audio
    case pdf
    case text
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        case .pdf: return "PDF"
        case .text: return "文本"
        case .archive: return "压缩包"
        }
    }

    /// 文件类型与该 UTType 一致即命中本类别
    var contentType: UTType {
        switch self {
        case .image: return .image
        case .video: return .movie
        case .audio: return .audio
        case .pdf: return .pdf
        case .text: return .plainText
        case .archive: return .archive
        }
    }

    /// 查询候选应用时使用的代表性扩展名。
    /// 系统只按真实文件查关联应用，空路径查不到，所以会临时落一个空文件再查。
    var sampleExtension: String {
        switch self {
        case .image: return "png"
        case .video: return "mov"
        case .audio: return "mp3"
        case .pdf: return "pdf"
        case .text: return "txt"
        case .archive: return "zip"
        }
    }
}
