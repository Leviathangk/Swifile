import AppKit
import Foundation

// MARK: - 系统权限探测

/// TCC 权限探测与系统设置直达链接。
/// 注意两类服务的弹窗行为完全不同：
/// - 完全磁盘访问（AllFiles）永远不会自动弹窗，读受保护路径只会被拒绝 → 可以放心探测；
/// - 单个文件夹（桌面/文档/下载…）的服务会在未授权时自动弹窗 → 绝不探测，只做跳转。
enum SystemPermissionChecker {
    /// 完全磁盘访问：用户级 TCC.db 只有获此权限的应用可读（首选探针）；
    /// 退路是列举 ~/Library/Safari，同样只在完全磁盘访问下放行。
    static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tccDB = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        if (try? Data(contentsOf: tccDB)) != nil { return true }

        let safari = home.appendingPathComponent("Library/Safari")
        return (try? FileManager.default.contentsOfDirectory(atPath: safari.path(percentEncoded: false))) != nil
    }

    /// 在访达中显示应用本体：手动拖进系统设置授权列表用。
    static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// 系统设置 > 隐私与安全性 > 文件与文件夹
    static func openFilesAndFoldersSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    /// 系统设置 > 隐私与安全性 > 完全磁盘访问
    static func openFullDiskAccessSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
