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

    /// 申请完全磁盘访问：读另一个 App 的容器目录（AllFiles 保护）触发系统确认弹窗。
    /// 应用只有在发起过这类访问后才会出现在「完全磁盘访问」列表里（拒绝也会留记录）；
    /// 纯 API 无法主动登记。随后打开系统设置直达授权页，保证两条路都走得通。
    @MainActor
    static func requestFullDiskAccess() {
        let mailContainer = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.mail")
        _ = try? FileManager.default.contentsOfDirectory(atPath: mailContainer.path(percentEncoded: false))

        // 给系统弹窗留出展示时间，再打开授权页；没弹窗时也能直达列表
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        }
    }

    /// 在访达中显示应用本体：手动拖进系统设置授权列表用（最可靠的路）
    static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
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
