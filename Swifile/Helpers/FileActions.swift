import AppKit
import Foundation
import SwiftUI

// MARK: - 文件操作动作

/// 文件操作的共享实现。
/// 列表视图的自定义菜单（NSMenu）与其它视图的 SwiftUI 右键菜单都调用这里，
/// 避免同一套动作在多处各写一份、行为逐渐分叉。
@MainActor
enum FileActions {
    /// 打开：目录进入下一层，文件交给系统默认应用
    static func open(_ files: [FileItem], openDirectory: (FileItem) -> Void) {
        for file in files {
            if file.isDirectory {
                openDirectory(file)
            } else {
                NSWorkspace.shared.open(file.url)
            }
        }
    }

    /// 用其他应用打开
    static func openWith(_ file: FileItem) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = "选择应用"
        panel.prompt = "打开"
        if panel.runModal() == .OK, let appURL = panel.url {
            NSWorkspace.shared.open(
                [file.url],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    static func revealInFinder(_ files: [FileItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(files.map(\.url))
    }

    /// 在终端中打开：目录直接进入，文件则进入它所在的目录。
    /// 走 `open -a Terminal`：不依赖 AppleScript，避免"自动化"权限被拒时整条动作静默失败。
    static func openInTerminal(_ file: FileItem) {
        let dir = file.isDirectory ? file.url : file.url.deletingLastPathComponent()
        openInTerminal(at: dir)
    }

    /// 在终端中打开指定目录（空白区域右键用）
    static func openInTerminal(at directory: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", directory.path(percentEncoded: false)]
        do {
            try process.run()
        } catch {
            NSLog("Failed to open Terminal at \(directory.path(percentEncoded: false)): \(error)")
        }
    }

    /// 在 Finder 中显示某个目录本身（空白区域右键用）
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 拷贝单个路径（空白区域右键用）
    static func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path(percentEncoded: false), forType: .string)
    }

    /// 在当前目录下新建文件夹，重名时自动加序号
    static func createFolder(in directory: URL, onComplete: @escaping () -> Void) {
        Task {
            let manager = FileManager.default
            var name = "未命名文件夹"
            var target = directory.appendingPathComponent(name, isDirectory: true)
            var index = 2
            while manager.fileExists(atPath: target.path(percentEncoded: false)) {
                name = "未命名文件夹 \(index)"
                target = directory.appendingPathComponent(name, isDirectory: true)
                index += 1
            }
            do {
                try manager.createDirectory(at: target, withIntermediateDirectories: false)
                await FileSystemHelper.invalidateCache(for: directory)
            } catch {
                NSLog("Failed to create folder at \(target.path(percentEncoded: false)): \(error)")
            }
            await MainActor.run { onComplete() }
        }
    }

    static func copyURLs(_ files: [FileItem]) {
        let urls = files.map(\.url) as [NSURL]
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
    }

    static func copyPaths(_ files: [FileItem]) {
        let paths = files.map { $0.url.path(percentEncoded: false) }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths, forType: .string)
    }

    static func addToStaging(_ files: [FileItem], staging: StagingState) {
        staging.stageItems(files)
    }

    /// 添加到快速访问：扁平引用列表，重复路径由数据层自动跳过
    static func addToQuickAccess(_ files: [FileItem], manager: QuickAccessManager) {
        manager.add(urls: files.map(\.url))
    }

    /// 移到废纸篓，完成后回调（通常用于刷新所在目录）
    static func moveToTrash(_ files: [FileItem], onComplete: @escaping () -> Void) {
        let urls = files.map(\.url)
        Task {
            for url in urls {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    NSLog("Failed to trash \(url.path): \(error)")
                }
            }
            if let dir = urls.first?.deletingLastPathComponent() {
                await FileSystemHelper.invalidateCache(for: dir)
            }
            await MainActor.run { onComplete() }
        }
    }
}

// MARK: - 菜单命令

/// 右键菜单里的一条命令。
/// 标题与图标只在这里定义一次：SwiftUI 菜单（列视图、图标视图、列表视图外的场景）
/// 和列表视图的 AppKit 菜单都从这里渲染，避免两边各写一份、日后逐渐走样。
enum FileMenuCommand: String {
    case open
    case openWith
    case quickLook
    case revealInFinder
    case openInTerminal
    case copy
    case copyPath
    case addToQuickAccess
    case addToStaging
    case moveToTrash
    case newFolder
    case copyDirectoryPath
    case refresh

    var title: String {
        switch self {
        case .open: return "打开"
        case .openWith: return "用其他应用打开…"
        case .quickLook: return "快速预览"
        case .revealInFinder: return "在 Finder 中显示"
        case .openInTerminal: return "在终端中打开"
        case .copy: return "拷贝"
        case .copyPath, .copyDirectoryPath: return "拷贝路径"
        case .addToQuickAccess: return "添加到快速访问"
        case .addToStaging: return "添加到暂存区"
        case .moveToTrash: return "移到废纸篓"
        case .newFolder: return "新建文件夹"
        case .refresh: return "刷新"
        }
    }

    /// SF Symbol 名；「打开」「用其他应用打开」在系统菜单里本来就没有图标
    var symbol: String? {
        switch self {
        case .open, .openWith: return nil
        case .quickLook: return "eye"
        case .revealInFinder: return "magnifyingglass"
        case .openInTerminal: return "terminal"
        case .copy: return "doc.on.doc"
        case .copyPath, .copyDirectoryPath: return "doc.on.clipboard"
        case .addToQuickAccess: return "pin"
        case .addToStaging: return "tray.and.arrow.down"
        case .moveToTrash: return "trash"
        case .newFolder: return "folder.badge.plus"
        case .refresh: return "arrow.clockwise"
        }
    }

    var isDestructive: Bool { self == .moveToTrash }

    /// AppKit 菜单项图标：与 SwiftUI 侧读同一个 SF Symbol 名。
    /// 统一到 16pt 见方，菜单行高才不会因图标尺寸不同而跳动。
    var menuImage: NSImage? {
        guard let symbol,
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

// MARK: - 文件右键菜单

/// 文件右键菜单：列视图与图标视图共用，动作全部走 FileActions。
/// 列表视图因为宿主是 NSTableView，仍用 AppKit 菜单，但同样按 FileMenuCommand 渲染。
struct FileContextMenu: View {
    let files: [FileItem]
    let staging: StagingState
    let preview: PreviewState
    let quickAccess: QuickAccessManager
    let onOpenDirectory: (FileItem) -> Void
    let onRefresh: () -> Void

    var body: some View {
        FileMenuButton(command: .open) {
            FileActions.open(files, openDirectory: onOpenDirectory)
        }
        FileMenuButton(command: .openWith) {
            guard let first = files.first else { return }
            FileActions.openWith(first)
        }
        FileMenuButton(command: .quickLook) {
            if let first = files.first {
                preview.item = first
            }
        }

        Divider()

        FileMenuButton(command: .revealInFinder) {
            FileActions.revealInFinder(files)
        }
        FileMenuButton(command: .openInTerminal) {
            guard let first = files.first else { return }
            FileActions.openInTerminal(first)
        }

        Divider()

        FileMenuButton(command: .copy) {
            FileActions.copyURLs(files)
        }
        FileMenuButton(command: .copyPath) {
            FileActions.copyPaths(files)
        }

        Divider()

        FileMenuButton(command: .addToQuickAccess) {
            FileActions.addToQuickAccess(files, manager: quickAccess)
        }
        FileMenuButton(command: .addToStaging) {
            FileActions.addToStaging(files, staging: staging)
        }

        Divider()

        FileMenuButton(command: .moveToTrash) {
            FileActions.moveToTrash(files) { onRefresh() }
        }
    }
}

// MARK: - 目录右键菜单

/// 空白区域右键菜单：作用于当前显示的目录本身。
/// 列表视图用等价的 AppKit 菜单，动作同样走 FileActions。
struct DirectoryContextMenu: View {
    let directory: URL
    let onRefresh: () -> Void

    var body: some View {
        FileMenuButton(command: .newFolder) {
            FileActions.createFolder(in: directory) { onRefresh() }
        }

        Divider()

        FileMenuButton(command: .revealInFinder) {
            FileActions.reveal(directory)
        }
        FileMenuButton(command: .openInTerminal) {
            FileActions.openInTerminal(at: directory)
        }

        Divider()

        FileMenuButton(command: .copyDirectoryPath) {
            FileActions.copyPath(directory)
        }

        Divider()

        FileMenuButton(command: .refresh) {
            onRefresh()
        }
    }
}

// MARK: - 菜单项渲染

/// 菜单项标题：图标与文字都取自 FileMenuCommand
struct FileMenuLabel: View {
    let command: FileMenuCommand

    var body: some View {
        if let symbol = command.symbol {
            Label(command.title, systemImage: symbol)
        } else {
            Text(command.title)
        }
    }
}

/// 一般菜单项：动作由调用方给出
struct FileMenuButton: View {
    let command: FileMenuCommand
    let action: () -> Void

    var body: some View {
        Button(role: command.isDestructive ? .destructive : nil, action: action) {
            FileMenuLabel(command: command)
        }
    }
}
