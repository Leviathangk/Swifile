import AppKit
import Foundation

// MARK: - 文件剪贴板

/// 文件剪贴板：在系统剪贴板里读写「待搬运的文件」。
///
/// 除了标准的 file URL，还用一个自定义类型标记「这次是剪切」：
/// 粘贴时读到标记就用移动语义，否则复制。与访达、Windows 资源管理器的
/// 操作习惯一致，也不影响往访达里粘贴（访达只认其中的 file URL）。
enum FileClipboard {
    /// 自定义类型：存在即表示这批 URL 来自「剪切」
    static let cutType = NSPasteboard.PasteboardType("com.swifile.cut")

    struct Contents {
        let urls: [URL]
        let isCut: Bool
    }

    /// 写入剪贴板。asCut 为 true 时额外打上剪切标记。
    static func write(_ urls: [URL], asCut: Bool) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        if asCut {
            pasteboard.setData(Data(), forType: cutType)
        }
    }

    /// 读取剪贴板里的文件。没有文件时返回 nil（文本、图片等当作不支持）。
    static func read() -> Contents? {
        let pasteboard = NSPasteboard.general
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        guard !urls.isEmpty else { return nil }
        return Contents(urls: urls, isCut: pasteboard.data(forType: cutType) != nil)
    }

    /// 剪贴板里是否有可粘贴的文件（菜单可用性判断用）
    static var hasFiles: Bool {
        NSPasteboard.general.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    /// 剪切粘贴完成后清空：一次剪切只生效一次，
    /// 否则再按一次 ⌘V 会把同一批文件移动两次。
    static func clear() {
        NSPasteboard.general.clearContents()
    }
}
